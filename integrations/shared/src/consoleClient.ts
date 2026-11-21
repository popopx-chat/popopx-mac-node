/**
 * The console client. One port, one token, one in-flight command at a time.
 *
 * Everything here is constrained by measurements recorded in `integrations/CONTRACT.md`:
 * loopback only (§1), `X-PPX-Token` or `?t=` (§2), `POST /api/engine/invoke` as the only
 * executable path (§6), and at most one outstanding command because the node's single actor already
 * serialises them (§8). The response shapes mirror `CommandResult`
 * (`Sources/PopopxMacNode/Models/MacNodeModels.swift:1152-1176`, ISO-8601 dates via `:398-406`) and
 * `WEBHealth` (`Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3851-3861`).
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { BridgeError, isRetryable } from "./errors.js";
import {
  CONSOLE_TOKEN_HEADER,
  DEFAULT_CONSOLE_HOST,
  DEFAULT_CONSOLE_PORT,
  assertSendable,
  parseWireLine,
  type ParseResult,
  type WireCommand
} from "./wireCommand.js";
import { EventStream, type NodeEvent } from "./eventStream.js";

export const ROUTE = {
  health: "/api/health",
  snapshot: "/api/snapshot",
  events: "/api/events",
  engineInvoke: "/api/engine/invoke",
  command: "/api/command"
} as const;

export interface CommandResult {
  readonly id: string;
  readonly commandID: string | null;
  readonly engine: string;
  readonly ok: boolean;
  readonly deterministic: boolean;
  readonly headline: string;
  readonly body: string;
  readonly artifacts: readonly string[];
  readonly durationMs: number;
  readonly at: string;
  readonly metrics: Readonly<Record<string, unknown>>;
}

export interface NodeHealth {
  readonly ok: boolean;
  readonly service: string;
  readonly version: string;
  readonly node: string;
  readonly consolePort: number;
  readonly loopback: boolean;
  readonly viewers: number;
  readonly uptimeSeconds: number;
  readonly serverTime: string;
}

export interface ConsoleTarget {
  readonly origin: string;
  readonly host: string;
  readonly port: number;
  readonly token: string;
}

const LOOPBACK_HOSTS: readonly string[] = ["127.0.0.1", "localhost", "::1", "[::1]"];

/**
 * Node's `fetch` reports a refused connection as `TypeError: fetch failed` with the real reason on
 * `cause.code`, so the code has to be read through both shapes.
 */
function transportCode(error: unknown): string | undefined {
  for (const candidate of [error, (error as { cause?: unknown })?.cause]) {
    if (candidate !== null && typeof candidate === "object") {
      const code = (candidate as { code?: unknown }).code;
      if (typeof code === "string") return code;
    }
  }
  return undefined;
}

/**
 * Accepts either a tokenised console URL (`http://127.0.0.1:18920/?t=…`) or a bare token, and
 * refuses any target that is not loopback. The refusal matters more than it looks: the token is a
 * bearer secret, so a configuration typo that points at a routable host would ship it in clear HTTP.
 */
export function resolveTarget(input: string, env: NodeJS.ProcessEnv = process.env): ConsoleTarget {
  const raw = input.trim();
  const tokenFromEnv = env["PPX_CONSOLE_TOKEN"]?.trim() ?? "";
  if (raw === "" && tokenFromEnv === "") {
    throw new BridgeError(
      "tokenRejected",
      "no console token: paste the URL the node printed, or set PPX_CONSOLE_TOKEN"
    );
  }

  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    const url = new URL(raw);
    const host = url.hostname;
    if (!LOOPBACK_HOSTS.includes(host)) {
      throw new BridgeError("nonLoopbackTarget", `console host must be loopback, got ${host}`);
    }
    if (url.protocol === "https:") {
      throw new BridgeError("nonLoopbackTarget", "the console is plain HTTP on loopback");
    }
    const token = url.searchParams.get("t") ?? tokenFromEnv;
    if (token === null || token === "") {
      throw new BridgeError("tokenRejected", "console URL carries no ?t= token and PPX_CONSOLE_TOKEN is unset");
    }
    const port = url.port === "" ? DEFAULT_CONSOLE_PORT : Number(url.port);
    return { origin: `${url.protocol}//${url.host}`, host, port, token };
  }

  const token = raw === "" ? tokenFromEnv : raw;
  const host = env["PPX_CONSOLE_HOST"] ?? DEFAULT_CONSOLE_HOST;
  if (!LOOPBACK_HOSTS.includes(host)) {
    throw new BridgeError("nonLoopbackTarget", `PPX_CONSOLE_HOST must be loopback, got ${host}`);
  }
  const port = Number(env["PPX_CONSOLE_PORT"] ?? DEFAULT_CONSOLE_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new BridgeError("nonLoopbackTarget", `PPX_CONSOLE_PORT is not a port: ${String(env["PPX_CONSOLE_PORT"])}`);
  }
  return { origin: `http://${host}:${port}`, host, port, token };
}

export interface ConsoleOptions {
  readonly target: ConsoleTarget;
  readonly fetchImpl?: typeof fetch;
  readonly timeoutMs?: number;
  readonly allowLockdown?: boolean;
  readonly secret?: string;
}

export interface RunOutcome {
  readonly line: string;
  readonly parsed: ParseResult;
  readonly result?: CommandResult;
  readonly error?: BridgeError;
}

export class ConsoleClient {
  private readonly target: ConsoleTarget;
  private readonly fetchImpl: typeof fetch;
  private readonly timeoutMs: number;
  private readonly allowLockdown: boolean;
  private readonly secret: string;
  private inFlight: Promise<unknown> | null = null;

  constructor(options: ConsoleOptions) {
    this.target = options.target;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.allowLockdown = options.allowLockdown ?? false;
    this.secret = options.secret ?? "";
  }

  get origin(): string {
    return this.target.origin;
  }

  /** Never include this in a log line — it is the bearer secret. */
  get tokenFingerprint(): string {
    const tail = this.target.token.slice(-4);
    return `${this.target.token.length} chars, ends ${tail}`;
  }

  async health(): Promise<NodeHealth> {
    return await this.serialised(async () => {
      const response = await this.request(ROUTE.health, { method: "GET" });
      return await this.json<NodeHealth>(response);
    });
  }

  async snapshot(): Promise<Record<string, unknown>> {
    return await this.serialised(async () => {
      const response = await this.request(ROUTE.snapshot, { method: "GET" });
      return await this.json<Record<string, unknown>>(response);
    });
  }

  /**
   * Sends an already-parsed command. The policy check happens here as well as in `runLine`, so a
   * caller that builds a `WireCommand` by hand still cannot reach `lockdown`.
   */
  async invoke(command: WireCommand): Promise<CommandResult> {
    assertSendable(command, { allowLockdown: this.allowLockdown, secret: this.secret });
    return await this.serialised(async () => {
      const response = await this.request(ROUTE.engineInvoke, {
        method: "POST",
        body: JSON.stringify(command.invokeBody)
      });
      return await this.json<CommandResult>(response);
    });
  }

  /** The normal entry point: grammar first, policy second, socket third. */
  async runLine(line: string): Promise<RunOutcome> {
    const parsed = parseWireLine(line);
    if (!parsed.ok) return { line, parsed, error: undefined };
    try {
      const result = await this.invoke(parsed.command);
      return { line, parsed, result };
    } catch (error) {
      if (error instanceof BridgeError) return { line, parsed, error };
      throw error;
    }
  }

  /**
   * `/api/command` exists but its result is a refusal for every engine except the
   * deterministic-lock branch — see CONTRACT §6. It is kept for reading the node's own parse
   * verdicts, and refuses a lockdown line outright so it cannot be used as the second path.
   */
  async injectRaw(line: string): Promise<CommandResult> {
    const parsed = parseWireLine(line);
    if (!parsed.ok) throw new BridgeError("malformedCommand", parsed.reason);
    assertSendable(parsed.command, { allowLockdown: false, secret: this.secret });
    return await this.serialised(async () => {
      const response = await this.request(ROUTE.command, {
        method: "POST",
        body: JSON.stringify({ text: line })
      });
      return await this.json<CommandResult>(response);
    });
  }

  /**
   * One long-lived SSE reader. `options.maxReconnects: 0` asks for a single pass, which is what a
   * one-shot command wants; a monitor leaves the default so a full-queue finish comes straight back.
   */
  events(
    signal?: AbortSignal,
    options: { readonly maxReconnects?: number; readonly initialBackoffMs?: number } = {}
  ): EventStream {
    return new EventStream({
      url: `${this.target.origin}${ROUTE.events}?t=${encodeURIComponent(this.target.token)}`,
      fetchImpl: this.fetchImpl,
      ...(signal === undefined ? {} : { signal }),
      ...options
    });
  }

  private async request(path: string, init: { method: string; body?: string }): Promise<Response> {
    const headers: Record<string, string> = {
      [CONSOLE_TOKEN_HEADER]: this.target.token,
      Accept: "application/json"
    };
    if (init.body !== undefined) headers["Content-Type"] = "application/json";

    let response: Response;
    try {
      response = await this.fetchImpl(`${this.target.origin}${path}`, {
        method: init.method,
        headers,
        body: init.body,
        signal: AbortSignal.timeout(this.timeoutMs),
        redirect: "manual",
        duplex: init.body === undefined ? undefined : "half"
      } as RequestInit);
    } catch (error) {
      const name = (error as Error).name;
      if (name === "TimeoutError") {
        throw new BridgeError("nodeUnreachable", `no response within ${this.timeoutMs} ms`, {
          detail: "the node may still have run the command; check its result before resending"
        });
      }
      // A refused connection is the one transport failure that proves the engine never saw the
      // request, so it is the only one `invokeWithRetry` may resend. Anything later — a reset, a
      // timeout, a truncated body — leaves the outcome unknown, and `chrono_ark seal` or
      // `creator_paywall_hub grant` are not idempotent.
      const refused = transportCode(error) === "ECONNREFUSED";
      throw new BridgeError("nodeUnreachable", `${name}: ${(error as Error).message}`, {
        mayHaveExecuted: !refused,
        detail: refused
          ? `nothing is listening on ${this.target.origin} — is the node running? the console only exists while the app is up`
          : undefined
      });
    }

    if (response.status === 401) {
      throw new BridgeError("tokenRejected", await this.textOf(response), {
        status: 401,
        detail: `token ${this.tokenFingerprint}; a node restart mints a new one`
      });
    }
    if (response.status === 405) {
      throw new BridgeError("methodNotAllowed", await this.textOf(response), { status: 405 });
    }
    if (response.status === 411) {
      throw new BridgeError("lengthRequired", await this.textOf(response), { status: 411 });
    }
    if (response.status === 413) {
      throw new BridgeError("payloadTooLarge", await this.textOf(response), { status: 413 });
    }
    if (response.status >= 300 && response.status < 400) {
      throw new BridgeError(
        "badResponse",
        "the console answered with a redirect, which this client refuses to follow",
        { status: response.status }
      );
    }
    if (response.status === 404) {
      if (path === ROUTE.engineInvoke) {
        throw new BridgeError(
          "badResponse",
          "this console has no /api/engine/invoke route",
          {
            status: 404,
            detail: "the port answers, so it is probably not the node: 18920 is the only port this bridge speaks to"
          }
        );
      }
      throw new BridgeError("badResponse", await this.textOf(response), { status: 404 });
    }
    if (response.status >= 500) {
      throw new BridgeError("nodeBusy", await this.textOf(response), { status: response.status });
    }
    if (!response.ok) {
      throw new BridgeError("badResponse", await this.textOf(response), { status: response.status });
    }
    return response;
  }

  private async textOf(response: Response): Promise<string> {
    try {
      return (await response.text()).slice(0, 400);
    } catch {
      return "<unreadable body>";
    }
  }

  /**
   * Not `textOf`: a real `CommandResult` is longer than an error string, and the node truncates the
   * result body at 1 800 characters (`MacNodeModels.swift:1196-1200`), so anything under that must
   * reach the parser whole.
   */
  private async json<T>(response: Response): Promise<T> {
    let text: string;
    try {
      text = await response.text();
    } catch (error) {
      throw new BridgeError("badResponse", `response body could not be read: ${(error as Error).message}`, {
        status: response.status
      });
    }
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new BridgeError("badResponse", `node replied with non-JSON: ${text.slice(0, 400)}`, {
        status: response.status
      });
    }
  }

  /**
   * The node serialises engines in one actor (CONTRACT §8), so a second queue here would only add a
   * place for commands to be reordered. One at a time, and a concurrent caller is told rather than
   * queued silently.
   */
  private async serialised<T>(work: () => Promise<T>): Promise<T> {
    if (this.inFlight !== null) {
      throw new BridgeError(
        "inFlightLimit",
        "another command is already in flight for this node",
        { detail: "the node runs one command at a time; await the first" }
      );
    }
    const task = work();
    this.inFlight = task;
    try {
      return await task;
    } finally {
      this.inFlight = null;
    }
  }

  /**
   * One retry, and only when the failure proves the node never received the request: a retryable
   * *code* is necessary but not sufficient, because `chrono_ark seal` and `creator_paywall_hub grant`
   * are not idempotent and a lost answer is not proof that nothing ran.
   */
  async invokeWithRetry(command: WireCommand): Promise<CommandResult> {
    try {
      return await this.invoke(command);
    } catch (error) {
      if (error instanceof BridgeError && isRetryable(error.code) && !error.outcomeUnknown) {
        return await this.invoke(command);
      }
      throw error;
    }
  }
}

export type { NodeEvent };

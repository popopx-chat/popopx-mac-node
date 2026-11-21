/**
 * The one handler behind all ten tools: `(service, action, payload)` in, a canonical wire line out,
 * submitted through `@popopx/node-bridge`.
 *
 * Order is the whole design, and it is fixed:
 *
 *   1. resolve the service id (aliases included) and the canonical action name — a bad name is
 *      refused here, locally, with the list of real ones, so the node is never asked to explain
 *      a typo (`CONTRACT.md` §5 · 第 5 节);
 *   2. apply the lockdown policy with `assertSendable`, on a probe line carrying an empty object,
 *      so a refusal costs no bytes of payload parsing and, above all, no socket — this is the
 *      compensation for the node-side ordering in `CONTRACT.md` §7 · 第 7 节, where `invoke()`
 *      reaches the lock trigger before it consults `isEnabled` and never checks `authenticated`;
 *   3. render the canonical line and let `parseWireLine` own the grammar, the 1 024-grapheme budget
 *      and the "payload must be a JSON object" rule, because the executable route decodes it as a
 *      dictionary (`Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`);
 *   4. only now construct the bridge, so a refusal or a typo cannot resolve a target, and a
 *      misconfigured handoff is reported as a typed result instead of an exception;
 *   5. `invokeWithRetry`, which sends at most once, resends at most once and only when the failure
 *      proves the node never saw the request (`CONTRACT.md` §8 · 第 8 节).
 *
 * Nothing here re-implements the wire grammar or the policy: both live in `@popopx/node-bridge`,
 * imported from the barrel so the gate cannot be reached around.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import {
  COMMAND_PREFIX,
  ROUTES,
  SERVICE_IDS,
  assertSendable,
  BridgeError,
  canonicalAction,
  describeError,
  graphemeCount,
  NodeBridge,
  normaliseAction,
  parseWireLine,
  resolveServiceId,
  type BridgeErrorCode,
  type CommandResult,
  type ServiceId,
  type WireCommand
} from "@popopx/node-bridge";

import { BridgeLogger, type LogFields } from "../log.js";

/** Every failure this plugin can report, whether or not the kernel has a code for it. */
export type ToolCode =
  | BridgeErrorCode
  // Local refusals the host needs to tell apart from transport trouble.
  | "invalidPayload"
  | "unknownAction"
  | "engineRefused"
  | "internalError";

export interface ToolResult {
  readonly ok: boolean;
  readonly code?: ToolCode;
  readonly message?: string;
  readonly headline?: string;
  readonly body?: string;
  readonly artifacts?: readonly string[];
  readonly durationMs?: number;
}

export interface ServiceToolDefinition {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: Readonly<Record<string, unknown>>;
}

export interface RouterOptions {
  /** A tokenised console URL or a bare token; empty means "read `PPX_CONSOLE_TOKEN`". */
  readonly handoff?: string;
  readonly env?: NodeJS.ProcessEnv;
  readonly fetchImpl?: typeof fetch;
  readonly timeoutMs?: number;
  /** Default false. Even when true, `assertSendable` still demands a 16-character secret. */
  readonly allowLockdown?: boolean;
  readonly secret?: string;
  readonly logger?: BridgeLogger;
  readonly now?: () => number;
}

/** Presentation text only; the routing table is the kernel's, never a copy of it. */
const SERVICE_PRESENTATION: Readonly<Record<ServiceId, { readonly title: string; readonly summary: string }>> = {
  shadow_cos: {
    title: "Chief of Staff briefing",
    summary: "Builds the daily briefing and the negotiation prompt from what the node already knows."
  },
  zero_trust_warroom: {
    title: "War room attribution",
    summary: "Assigns a document, embeds the watermark, traces a copy back, and reads the registry."
  },
  zerotrace_studio: {
    title: "Metadata sanitising studio",
    summary: "Sanitises a file, strips metadata on its own, anchors a clip, or shreds what was made."
  },
  solo_autopilot: {
    title: "Solo video pipeline",
    summary: "Runs the one-person video pipeline and writes the script it needs first."
  },
  edge_compute_mesh: {
    title: "Edge compute sharing",
    summary: "Reports mesh status, offers and executes work, drains the queue, toggles sharing, settles."
  },
  morning_tv: {
    title: "Morning broadcast",
    summary: "Broadcasts the morning reel, digests the feeds, fires a scheduled slot, reads the schedule."
  },
  phantom_sentinel: {
    title: "Sentinel report",
    summary: "Reads the sentinel status only. The lockdown action is refused by this plugin, not hidden."
  },
  chrono_ark: {
    title: "Time-locked vault",
    summary: "Seals a vault, lists them, unseals one, answers heartbeat and release checks, reveals a folder."
  },
  health_sentinel: {
    title: "Health read and audio",
    summary: "Interprets an exported health record and generates the binaural track."
  },
  creator_paywall_hub: {
    title: "Entitlement verification",
    summary: "Verifies a ticket, grants and delivers it, claims a red packet, reads the ledger."
  }
};

export const TOOL_PREFIX = "popopx_";

/**
 * One tool per service, built straight from `ROUTES`, so a tool can only ever offer an action the
 * node actually routes — and never an action the kernel denies. `""` is absent on purpose: the node
 * treats an empty action as its default, the bridge refuses it (`CONTRACT.md` §3 · 第 3 节).
 */
export function buildToolDefinitions(): readonly ServiceToolDefinition[] {
  return SERVICE_IDS.map((id) => {
    const table = ROUTES[id];
    const presentation = SERVICE_PRESENTATION[id];
    const allowed = tableAllowedActions(id);
    const denied = table.denied;
    const actionNote =
      denied.length > 0
        ? `Refused by this plugin, whatever the node would do: ${denied.map(describeSpelling).join(", ")} - see CONTRACT.md section 7.`
        : "Every listed name is routed by the node; the first of each group is the canonical spelling this bridge sends.";
    return {
      name: `${TOOL_PREFIX}${id}`,
      description: `${presentation.title}. ${presentation.summary} ${actionNote}`,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["action"],
        properties: {
          action: {
            type: "string",
            enum: allowed,
            description: `Canonical action, or any spelling the node also accepts. One of: ${allowed.join(", ")}.`
          },
          payload: {
            type: "object",
            additionalProperties: true,
            description:
              "JSON object sent verbatim to POST /api/engine/invoke as `payload`. Defaults to an empty object; the whole wire line is budgeted at 1 024 grapheme clusters."
          }
        }
      }
    };
  });
}

function describeSpelling(action: string): string {
  return action === "" ? "empty action" : `"${action}"`;
}

/**
 * Every spelling the host may send for a service, canonical names first: the routing table minus the
 * names `assertSendable` refuses. Derived from `ROUTES` rather than re-typed, so this file cannot
 * drift away from the kernel.
 */
export function tableAllowedActions(id: ServiceId): readonly string[] {
  const table = ROUTES[id];
  const denied = new Set<string>(table.denied);
  const canonical = table.canonical.filter((name) => !denied.has(name));
  const aliases: string[] = [];
  for (const [spelling, target] of Object.entries(table.aliases)) {
    if (denied.has(target) || canonical.includes(spelling) || spelling === "") continue;
    aliases.push(spelling);
  }
  return [...canonical, ...aliases.sort()];
}

function truthyFlag(value: string | undefined): boolean {
  if (value === undefined) return false;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

export class TenServicesRouter {
  readonly logger: BridgeLogger;
  private readonly handoff: string;
  private readonly env: NodeJS.ProcessEnv;
  private readonly fetchImpl: typeof fetch | undefined;
  private readonly timeoutMs: number;
  private readonly allowLockdown: boolean;
  private readonly secret: string;
  private readonly clock: () => number;
  private bridge: NodeBridge | null = null;

  constructor(options: RouterOptions = {}) {
    const env = options.env ?? process.env;
    this.env = env;
    this.handoff = options.handoff ?? env["PPX_BRIDGE_HANDOFF"] ?? "";
    this.fetchImpl = options.fetchImpl;
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.allowLockdown = options.allowLockdown ?? truthyFlag(env["PPX_ALLOW_LOCKDOWN"]);
    this.secret = options.secret ?? env["PPX_BRIDGE_SECRET"] ?? "";
    this.logger = options.logger ?? new BridgeLogger();
    this.clock = options.now ?? Date.now;
    // Register the secret before the first line is written, so even a handoff mistake is scrubbed.
    this.protectHandoff();
  }

  /**
   * Handles one tool call. Never throws: a host that gets an exception out of a tool has nothing to
   * show the operator, so every failure becomes a typed `ToolResult` with a `code`.
   */
  async call(service: unknown, action: unknown, payload: unknown): Promise<ToolResult> {
    const started = this.clock();
    const id = typeof service === "string" ? resolveServiceId(service) : null;
    if (id === null) {
      return this.refuse("unknownService", started, {
        service: typeof service === "string" ? service.slice(0, 64) : typeof service,
        message: `Unknown service identifier. Known ids: ${SERVICE_IDS.join(", ")}.`
      });
    }

    if (typeof action !== "string") {
      return this.refuse("invalidPayload", started, {
        service: id,
        message: `action must be a string, got ${action === null ? "null" : typeof action}.`
      });
    }
    if (normaliseAction(action) === "") {
      return this.refuse("emptyAction", started, {
        service: id,
        message: `The node reads an empty action as its default; this bridge refuses it. Canonical actions for ${id}: ${ROUTES[id].canonical.join(", ")}.`
      });
    }
    const canonical = canonicalAction(id, action);
    if (canonical === null) {
      return this.refuse("unknownAction", started, {
        service: id,
        message: `unknown action "${action}" for ${id}. Canonical actions: ${ROUTES[id].canonical.join(
          ", "
        )}. Other accepted spellings: ${tableAllowedActions(id).join(", ")}.`
      });
    }

    // Policy first, on a probe line, before a single byte of payload is serialised.
    const policy = this.policyGate(id, canonical, started);
    if (policy !== null) return policy;

    const encoded = encodePayload(payload);
    if (!encoded.ok) {
      return this.refuse("invalidPayload", started, { service: id, action: canonical, message: encoded.reason });
    }

    const line = `${COMMAND_PREFIX}${id}::${canonical}::${encoded.text}`;
    const parsed = parseWireLine(line);
    if (!parsed.ok) {
      return this.refuse(parsed.code, started, { service: id, action: canonical, message: parsed.reason });
    }
    return await this.submit(parsed.command, started);
  }

  /**
   * The same pipeline for a caller that already holds a canonical wire line, which is what the
   * manual check in `README.md` uses. Grammar, policy and submission are identical.
   */
  async runLine(line: string): Promise<ToolResult> {
    const started = this.clock();
    const parsed = parseWireLine(line);
    if (!parsed.ok) {
      return this.refuse(parsed.code, started, { message: parsed.reason });
    }
    const command = parsed.command;
    if (command.denied) {
      const gate = this.policyGate(command.serviceId, command.action, started);
      if (gate !== null) return gate;
    }
    return await this.submit(command, started);
  }

  /**
   * `assertSendable` is the kernel's own gate; this only turns its exception into a logged refusal.
   * Returns `null` when the action is sendable.
   */
  private policyGate(id: ServiceId, canonical: string, started: number): ToolResult | null {
    if (!ROUTES[id].denied.includes(canonical)) return null;
    const probe = parseWireLine(`${COMMAND_PREFIX}${id}::${canonical}::{}`);
    if (!probe.ok) {
      return this.refuse(probe.code, started, { service: id, action: canonical, message: probe.reason });
    }
    try {
      assertSendable(probe.command, { allowLockdown: this.allowLockdown, secret: this.secret });
    } catch (error) {
      if (error instanceof BridgeError) {
        return this.refuse(error.code, started, {
          service: id,
          action: canonical,
          message: describeError(error),
          detail: error.detail ?? "no network call was made"
        });
      }
      return this.refuse("internalError", started, { service: id, action: canonical, message: describeError(error) });
    }
    // Opted in, secret present: the kernel says send it, and the node really does act.
    this.logger.warn("lockdownOptInGranted", {
      service: id,
      action: canonical,
      note: "the node clears the pasteboard, unmounts volumes, sleeps displays and suspends the session"
    });
    return null;
  }

  private async submit(command: WireCommand, started: number): Promise<ToolResult> {
    const bridgeOrFailure = this.bridgeFor();
    if (!("invokeWithRetry" in bridgeOrFailure)) return bridgeOrFailure;

    this.logger.info("commandSent", {
      service: command.serviceId,
      action: command.action,
      payloadGraphemes: graphemeCount(command.payload),
      origin: bridgeOrFailure.origin
    });
    try {
      const result = await bridgeOrFailure.invokeWithRetry(command);
      return this.success(command, result, started);
    } catch (error) {
      if (error instanceof BridgeError) {
        // `inFlightLimit` and `tokenRejected` are the two an operator acts on, so they get their own
        // events instead of one generic failure bucket.
        this.logger.warn(`commandFailed_${error.code}`, {
          service: command.serviceId,
          action: command.action,
          attemptLimit: error.outcomeUnknown ? "none, the node may already have acted" : "one resend",
          message: describeError(error)
        });
        return { ok: false, code: error.code, message: this.scrub(describeError(error)), durationMs: this.elapsed(started) };
      }
      this.logger.error("commandCrashed", {
        service: command.serviceId,
        action: command.action,
        message: describeError(error)
      });
      return {
        ok: false,
        code: "internalError",
        message: this.scrub(describeError(error)),
        durationMs: this.elapsed(started)
      };
    }
  }

  private success(command: WireCommand, result: CommandResult, started: number): ToolResult {
    const fields: LogFields = {
      service: command.serviceId,
      action: command.action,
      engineOk: result.ok,
      headline: result.headline,
      artifacts: result.artifacts.length,
      durationMs: result.durationMs,
      roundTripMs: this.elapsed(started)
    };
    if (result.ok) this.logger.info("commandDone", fields);
    else this.logger.warn("engineRefused", fields);
    return {
      ok: result.ok,
      headline: result.headline,
      body: result.body,
      artifacts: result.artifacts,
      durationMs: result.durationMs,
      ...(result.ok ? {} : { code: "engineRefused" as const })
    };
  }

  /** Lazily built and cached: one client per node means one in-flight slot per node (CONTRACT §8). */
  private bridgeFor(): NodeBridge | ToolResult {
    if (this.bridge !== null) return this.bridge;
    try {
      const bridge = new NodeBridge({
        handoff: this.handoff,
        env: this.env,
        timeoutMs: this.timeoutMs,
        allowLockdown: this.allowLockdown,
        secret: this.secret,
        ...(this.fetchImpl === undefined ? {} : { fetchImpl: this.fetchImpl })
      });
      this.bridge = bridge;
      this.logger.protect(bridge.target.token);
      this.logger.info("bridgeReady", { origin: bridge.origin, token: bridge.tokenFingerprint });
      return bridge;
    } catch (error) {
      if (error instanceof BridgeError) {
        this.logger.warn(`handoffRejected_${error.code}`, { message: describeError(error) });
        return { ok: false, code: error.code, message: this.scrub(describeError(error)) };
      }
      this.logger.error("handoffCrashed", { message: describeError(error) });
      return { ok: false, code: "internalError", message: this.scrub(describeError(error)) };
    }
  }

  /**
   * Belt and braces on the way out: a message is only ever built from error text and ids this
   * plugin knows, but a future kernel detail string that quotes the handoff must not reach the host.
   */
  private scrub(message: string): string {
    return this.logger.redact(message);
  }

  private refuse(code: ToolCode, started: number, fields: LogFields): ToolResult {
    const { message, detail, ...rest } = fields;
    this.logger.warn(`refused_${code}`, {
      ...rest,
      fetches: 0,
      ...(typeof message === "string" ? { message } : {}),
      ...(typeof detail === "string" ? { detail } : {})
    });
    const reported = typeof message === "string" ? message : `refused with ${code}`;
    return {
      ok: false,
      code,
      message: this.scrub(typeof detail === "string" ? `${reported}\n  ${detail}` : reported),
      durationMs: this.elapsed(started)
    };
  }

  private protectHandoff(): void {
    const fromEnv = this.env["PPX_CONSOLE_TOKEN"];
    if (typeof fromEnv === "string") this.logger.protect(fromEnv);
    const fromBridgeSecret = this.secret;
    if (fromBridgeSecret !== "") this.logger.protect(fromBridgeSecret);
    // A pasted handoff is `http://127.0.0.1:18920/?t=<token>`: scrub the token it carries.
    try {
      const url = new URL(this.handoff);
      const token = url.searchParams.get("t");
      if (typeof token === "string") this.logger.protect(token);
    } catch {
      // A bare token is not a URL; register it whole, since that is what it is.
      if (this.handoff !== "" && !this.handoff.startsWith("http")) this.logger.protect(this.handoff);
    }
  }

  private elapsed(started: number): number {
    return Math.max(0, this.clock() - started);
  }
}

function encodePayload(payload: unknown): { ok: true; text: string } | { ok: false; reason: string } {
  if (payload === undefined || payload === null) return { ok: true, text: "{}" };
  if (Array.isArray(payload)) {
    return { ok: false, reason: "payload must be a JSON object: /api/engine/invoke decodes it as a dictionary." };
  }
  if (typeof payload !== "object") {
    return {
      ok: false,
      reason: `payload must be a JSON object, got ${typeof payload}: /api/engine/invoke decodes it as a dictionary.`
    };
  }
  try {
    const text = JSON.stringify(payload);
    if (text === undefined) return { ok: false, reason: "payload serialised to nothing; send a plain object." };
    return { ok: true, text };
  } catch (error) {
    return { ok: false, reason: `payload could not be serialised: ${(error as Error).name}` };
  }
}

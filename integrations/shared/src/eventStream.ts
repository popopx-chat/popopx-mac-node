/**
 * Reader for the console's event stream, which is the node's only push channel.
 *
 * Frame format is fixed by `WEBSSEChannel.frame(for:)` in
 * `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift`: each event is
 *
 *     event: <channel>\ndata: <compact JSON of the whole ConsoleEvent>\n\n
 *
 * preceded once by a `retry: 3000` preamble, interleaved with the comment heartbeat
 * `: ppx heartbeat\n\n`, and bounded by 64 queued events per viewer — after which the server
 * *finishes* the stream instead of dropping silently. There is no `id:` field and no replay, so a
 * reconnect can miss events: a bridge must reconcile with `GET /api/snapshot` rather than assume it
 * saw everything (CONTRACT §9 · 第 9 节).
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { BridgeError } from "./errors.js";

export const EVENT_CHANNELS = [
  "install",
  "pairing",
  "engine",
  "bridge",
  "result",
  "mesh",
  "sentinel",
  "settings",
  "system"
] as const;

export type EventChannel = (typeof EVENT_CHANNELS)[number];

export interface NodeEvent {
  readonly channel: EventChannel | string;
  readonly level: string;
  readonly message: string;
  /** ISO-8601, because `NodeJSON` encodes dates that way (`MacNodeModels.swift:398-406`). */
  readonly at: string;
  readonly payload: Readonly<Record<string, unknown>>;
}

export interface EventStreamOptions {
  readonly url: string;
  readonly fetchImpl?: typeof fetch;
  readonly signal?: AbortSignal;
  /**
   * How many consecutive passes that delivered nothing may be retried. `0` means "read one pass and
   * stop", which is what a one-shot command wants; a monitor wants a larger number because the node
   * ends a stream on purpose once 64 events have queued.
   */
  readonly maxReconnects?: number;
  readonly initialBackoffMs?: number;
}

export interface Frame {
  readonly event: string | null;
  readonly data: readonly string[];
  readonly retryMs: number | null;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

/** Splits one buffer into complete frames and returns the bytes left over. */
export function splitFrames(buffer: string): { readonly frames: readonly Frame[]; readonly rest: string } {
  const frames: Frame[] = [];
  let cursor = 0;
  for (;;) {
    const boundary = indexOfBoundary(buffer, cursor);
    if (boundary === null) break;
    frames.push(parseFrame(buffer.slice(cursor, boundary.index)));
    cursor = boundary.index + boundary.length;
  }
  return { frames, rest: buffer.slice(cursor) };
}

function indexOfBoundary(text: string, from: number): { index: number; length: number } | null {
  const lf = text.indexOf("\n\n", from);
  const crlf = text.indexOf("\r\n\r\n", from);
  if (lf < 0 && crlf < 0) return null;
  if (crlf >= 0 && (lf < 0 || crlf < lf)) return { index: crlf, length: 4 };
  return { index: lf, length: 2 };
}

function parseFrame(chunk: string): Frame {
  let event: string | null = null;
  const data: string[] = [];
  let retryMs: number | null = null;
  for (const line of chunk.split(/\r?\n/)) {
    if (line === "" || line.startsWith(":")) continue; // blank, or a comment heartbeat
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    else if (field === "data") data.push(value);
    else if (field === "retry") {
      const parsed = Number(value);
      if (Number.isFinite(parsed) && parsed >= 0) retryMs = parsed;
    }
  }
  return { event, data, retryMs };
}

/**
 * A frame is either an event or a named failure. The `ok` flag is a discriminant on purpose: with
 * two optional fields instead, TypeScript cannot narrow `in` checks and every caller repeats the test.
 */
export type FrameDecode =
  | { readonly ok: true; readonly event: NodeEvent }
  | { readonly ok: false; readonly error: string };

/** Turns one frame into a `NodeEvent`, or explains why it cannot be one. */
export function decodeFrame(frame: Frame): FrameDecode {
  const text = frame.data.join("\n");
  if (text === "") return { ok: false, error: "frame carried no data" };
  let decoded: unknown;
  try {
    decoded = JSON.parse(text);
  } catch (error) {
    return { ok: false, error: `data is not JSON: ${(error as Error).name}` };
  }
  if (!isRecord(decoded)) return { ok: false, error: "data is not a JSON object" };
  const fromBody = decoded["channel"];
  const channel = typeof fromBody === "string" ? fromBody : frame.event;
  if (typeof channel !== "string") return { ok: false, error: "frame has no channel" };
  const payload = isRecord(decoded["payload"]) ? decoded["payload"] : {};
  const level = decoded["level"];
  const message = decoded["message"];
  const at = decoded["at"];
  return {
    ok: true,
    event: {
      channel,
      level: typeof level === "string" ? level : "info",
      message: typeof message === "string" ? message : "",
      at: typeof at === "string" ? at : "",
      payload
    }
  };
}

export class EventStream {
  private readonly url: string;
  private readonly fetchImpl: typeof fetch;
  private readonly signal: AbortSignal | undefined;
  private readonly maxReconnects: number;
  private readonly initialBackoffMs: number;
  private readonly interrupt = new AbortController();
  /** The node's own `retry:` ask, once seen. */
  private serverRetryMs: number | null = null;
  private closed = false;

  constructor(options: EventStreamOptions) {
    this.url = options.url;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.signal = options.signal;
    this.maxReconnects = options.maxReconnects ?? 3;
    this.initialBackoffMs = options.initialBackoffMs ?? 1_000;
    if (this.signal !== undefined) {
      if (this.signal.aborted) this.interrupt.abort();
      else this.signal.addEventListener("abort", () => this.interrupt.abort(), { once: true });
    }
  }

  /** Ends iteration even while a read is outstanding, so a plugin can stop without a dangling socket. */
  close(): void {
    this.closed = true;
    this.interrupt.abort();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<NodeEvent, void, void> {
    let attempt = 0;
    let backoff = this.initialBackoffMs;
    while (!this.closed && !this.signal?.aborted) {
      let delivered = 0;
      let failure: BridgeError | undefined;
      try {
        for await (const event of this.pass()) {
          delivered += 1;
          yield event;
        }
      } catch (error) {
        if (this.closed || this.signal?.aborted) return;
        if (!(error instanceof BridgeError)) throw error;
        // A rejected token means the node restarted and minted a new one: reconnecting is a loop,
        // not a retry, and the operator has to paste a fresh handoff.
        if (error.code === "tokenRejected") throw error;
        if (error.code !== "nodeUnreachable") throw error;
        failure = error;
      }
      if (this.closed || this.signal?.aborted) return;
      // One pass only is a promise the caller made for us: it is honoured even when the pass ended
      // with an event in hand. Checked before the progress reset below, or a stream that keeps
      // delivering and then closing would reconnect forever.
      if (this.maxReconnects === 0) {
        if (failure !== undefined) throw failure;
        return;
      }
      // A pass that delivered events is progress, not a failure: the node ends a stream on purpose
      // once its 64-deep queue drains, and a monitor is meant to come straight back.
      if (delivered > 0) {
        attempt = 0;
        backoff = this.serverRetryMs ?? this.initialBackoffMs;
        continue;
      }
      if (attempt >= this.maxReconnects) {
        throw failure ?? new BridgeError(
          "nodeUnreachable",
          `the event stream opened ${attempt + 1} times without delivering an event`,
          {
            mayHaveExecuted: false,
            detail: "reconcile with GET /api/snapshot, then check the token against a node restart"
          }
        );
      }
      attempt += 1;
      // The node's `retry:` ask outruns the local schedule when it has been seen (3 000 ms today).
      await sleep(this.serverRetryMs ?? backoff, this.interrupt.signal);
      backoff = Math.min(backoff * 2, 16_000);
    }
  }

  private async *pass(): AsyncGenerator<NodeEvent, void, void> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.url, {
        method: "GET",
        headers: { Accept: "text/event-stream" },
        signal: this.interrupt.signal
      });
    } catch (error) {
      if (this.closed || this.signal?.aborted || this.interrupt.signal.aborted) return;
      throw new BridgeError("nodeUnreachable", `the event stream could not open: ${(error as Error).message}`, {
        mayHaveExecuted: false
      });
    }
    if (response.status === 401) {
      throw new BridgeError("tokenRejected", "the console refused the event stream", {
        status: 401,
        mayHaveExecuted: false
      });
    }
    if (response.status >= 500) {
      // Reading a stream has no side effect, so a 5xx here is worth another attempt.
      throw new BridgeError("nodeUnreachable", `the event stream answered HTTP ${response.status}`, {
        status: response.status,
        mayHaveExecuted: false
      });
    }
    if (!response.ok) {
      throw new BridgeError("badResponse", `the event stream answered HTTP ${response.status}`, {
        status: response.status,
        mayHaveExecuted: false
      });
    }
    if (response.body === null) return;

    const reader = response.body.getReader();
    const decoder = new TextDecoder("utf-8");
    let buffer = "";
    try {
      for (;;) {
        const chunk = await reader.read();
        if (chunk.done) break;
        buffer += decoder.decode(chunk.value, { stream: true });
        const split = splitFrames(buffer);
        buffer = split.rest;
        for (const frame of split.frames) {
          if (frame.retryMs !== null) this.serverRetryMs = frame.retryMs;
          if (frame.data.length === 0) continue; // the preamble and every heartbeat
          const decoded = decodeFrame(frame);
          if (!decoded.ok) {
            throw new BridgeError("badResponse", `undecodable event frame: ${decoded.error}`, {
              mayHaveExecuted: false
            });
          }
          yield decoded.event;
        }
      }
    } finally {
      reader.cancel().catch(() => undefined);
      reader.releaseLock();
    }
  }
}

async function sleep(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted || ms <= 0) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true }
    );
  });
}

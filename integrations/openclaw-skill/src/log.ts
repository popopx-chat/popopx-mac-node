/**
 * One-line JSON logging for the OpenClaw plugin, with the console token scrubbed out.
 *
 * Two rules shape this file. First: the token is a bearer secret that dies with the node process
 * (`integrations/CONTRACT.md` §2 · 第 2 节), so it may never be persisted, and a log line that
 * echoes a node error body could carry it by accident — every string that leaves here is scrubbed
 * twice, once against the registered secret values and once against the `?t=` and `X-PPX-Token`
 * shapes the console itself uses. Second: a host that loads a plugin usually owns stdout, so this
 * logger writes to stderr and never more than one line per event, which keeps the operator's
 * `tail -f` greppable and makes a refusal provable after the fact.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

export const REDACTED = "[redacted]";
export const TRUNCATED = "[truncated]";

export const LOG_LEVELS = ["info", "warn", "error"] as const;
export type LogLevel = (typeof LOG_LEVELS)[number];

export interface LogFields {
  readonly [key: string]: unknown;
}

export interface LogEntry {
  readonly at: string;
  readonly level: LogLevel;
  readonly namespace: string;
  readonly event: string;
  readonly fields: Readonly<Record<string, unknown>>;
}

export interface LoggerOptions {
  /** Where a finished line goes. Defaults to `process.stderr`. */
  readonly sink?: (line: string) => void;
  readonly namespace?: string;
  readonly clock?: () => Date;
  /** Long strings are cut to this many characters, so one event really is one line. */
  readonly maxValueChars?: number;
}

/** `?t=<token>`, which is how the SSE route and a pasted console URL carry the secret. */
const QUERY_TOKEN = /([?&]t=)[^\s&"']+/g;
/** `"X-PPX-Token": "<token>"` in any body that got logged verbatim. */
const HEADER_TOKEN = /("(?:x-ppx-token)"\s*:\s*")[^"]*(")/gi;
/** A bare base64url-looking secret sitting after the word token, as a last resort. */
const LABELLED_TOKEN = /((?:token|secret)["']?\s*[:=]\s*["']?)[A-Za-z0-9_-]{16,}(?=["'\s&]|$)/gi;

function defaultSink(line: string): void {
  process.stderr.write(line);
}

export class BridgeLogger {
  private readonly sink: (line: string) => void;
  private readonly namespace: string;
  private readonly clock: () => Date;
  private readonly maxValueChars: number;
  private readonly secrets: string[] = [];

  constructor(options: LoggerOptions = {}) {
    this.sink = options.sink ?? defaultSink;
    this.namespace = options.namespace ?? "popopx.openclaw";
    this.clock = options.clock ?? (() => new Date());
    this.maxValueChars = options.maxValueChars ?? 300;
  }

  /**
   * Registers a value that must never appear in a log line — the console token, and the plugin
   * shared secret. Call it as soon as the value is known, before any call that could fail.
   */
  protect(value: string): void {
    if (value === "") return;
    if (!this.secrets.includes(value)) this.secrets.push(value);
    const encoded = encodeURIComponent(value);
    if (encoded !== value && !this.secrets.includes(encoded)) this.secrets.push(encoded);
  }

  /** Removes every registered secret, plus the shapes the console carries them in. */
  redact(text: string): string {
    let out = text;
    for (const secret of this.secrets) {
      if (secret === "") continue;
      out = out.split(secret).join(REDACTED);
    }
    return out
      .replace(QUERY_TOKEN, `$1${REDACTED}`)
      .replace(HEADER_TOKEN, `$1${REDACTED}$2`)
      .replace(LABELLED_TOKEN, `$1${REDACTED}`);
  }

  info(event: string, fields: LogFields = {}): void {
    this.write("info", event, fields);
  }

  warn(event: string, fields: LogFields = {}): void {
    this.write("warn", event, fields);
  }

  error(event: string, fields: LogFields = {}): void {
    this.write("error", event, fields);
  }

  /** Serialises, scrubs and emits exactly one line. Never throws: logging must not break a call. */
  write(level: LogLevel, event: string, fields: LogFields = {}): void {
    const flat: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(fields)) flat[key] = this.clip(value);
    const entry: LogEntry = {
      at: this.clock().toISOString(),
      level,
      namespace: this.namespace,
      event: this.redact(event),
      fields: flat
    };
    this.sink(`${this.redact(this.serialize(entry))}\n`);
  }

  private serialize(entry: LogEntry): string {
    try {
      return JSON.stringify(entry);
    } catch {
      // A cyclic field must not take the call down with it.
      return JSON.stringify({
        at: entry.at,
        level: entry.level,
        namespace: entry.namespace,
        event: entry.event,
        fields: { unserializable: true }
      });
    }
  }

  private clip(value: unknown): unknown {
    if (typeof value === "string") {
      const text = this.redact(value);
      return text.length > this.maxValueChars ? `${text.slice(0, this.maxValueChars)} ${TRUNCATED}` : text;
    }
    if (Array.isArray(value)) return value.map((item) => this.clip(item));
    if (value !== null && typeof value === "object") {
      const out: Record<string, unknown> = {};
      for (const [key, item] of Object.entries(value as Record<string, unknown>)) out[key] = this.clip(item);
      return out;
    }
    return value;
  }
}

/**
 * One-line JSON logging for the Linger skill, with the console token kept out of every record.
 *
 * Two rules come from `integrations/CONTRACT.md` and both are enforced here rather than by
 * convention: §2 says the token is a bearer secret that is never persisted, so no record may carry
 * it — the identity of a token in a log line is `ConsoleClient.tokenFingerprint`, which is length
 * plus the last four characters and is safe to print. §7 says every refusal has to be visible to the
 * operator, so `refusal()` writes even when the rest of the logging is silenced.
 *
 * A record is always exactly one line: the field vocabulary is `string | number | boolean`, so
 * `JSON.stringify` escapes any newline the node put in a message instead of starting a second line.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

export type LogLevel = "info" | "warn" | "error";

export type LogField = string | number | boolean;

export type LogFields = Readonly<Record<string, LogField | undefined>>;

/** A record: what a scrubbed secret was replaced with. */
export const REDACTED = "[redacted]";

/** The skill's own name, on every line, so a mixed host log stays greppable. */
export const LOG_SKILL = "linger-skill";

/**
 * Names a caller must not be able to write, whatever it passes. The value is checked, not the
 * spelling: `token`, `secret` and the header name all land here.
 */
const FORBIDDEN_FIELDS: readonly string[] = [
  "token",
  "secret",
  "authorization",
  "x-ppx-token",
  "ppx_console_token",
  "handoff"
];

/** Below this length a scrub pattern would eat ordinary words, so it is ignored. */
const MIN_REDACTION_LENGTH = 4;

export interface LoggerOptions {
  /** Where a finished line goes. Defaults to `process.stderr`. Tests pass a collector. */
  readonly sink?: (line: string) => void;
  /** Literal strings to scrub out of every field: tokens, secrets, tokenised URLs. */
  readonly redact?: readonly string[];
  /** Suppresses `info` and `error`. `refusal()` ignores this: CONTRACT §7 has no opt-out. */
  readonly quiet?: boolean;
  /** Injectable clock, so a test can pin `ts` instead of pattern-matching it. */
  readonly now?: () => Date;
}

export interface LogRecord {
  readonly ts: string;
  readonly level: LogLevel;
  readonly event: string;
  readonly skill: string;
  readonly fields: Readonly<Record<string, LogField>>;
}

export class SkillLogger {
  private readonly sink: (line: string) => void;
  private readonly redactions: string[];
  private readonly quiet: boolean;
  private readonly clock: () => Date;

  constructor(options: LoggerOptions = {}) {
    this.sink = options.sink ?? ((line: string) => void process.stderr.write(`${line}\n`));
    this.redactions = [];
    for (const value of options.redact ?? []) this.addRedaction(value);
    this.quiet = options.quiet ?? false;
    this.clock = options.now ?? ((): Date => new Date());
  }

  /**
   * Registers a literal to scrub. This never stores anything in a record: the token arrives here
   * only so that a message the node echoed, or a URL a host repeated, cannot carry it out.
   */
  addRedaction(text: string): void {
    const value = text.trim();
    if (value.length < MIN_REDACTION_LENGTH) return;
    if (!this.redactions.includes(value)) this.redactions.push(value);
  }

  /** Replaces every registered secret with `REDACTED`. Idempotent. */
  scrub(text: string): string {
    let out = text;
    for (const value of this.redactions) out = out.split(value).join(REDACTED);
    return out;
  }

  info(event: string, fields: LogFields = {}): LogRecord | null {
    return this.emit("info", event, fields, this.quiet);
  }

  error(event: string, fields: LogFields = {}): LogRecord | null {
    return this.emit("error", event, fields, this.quiet);
  }

  /** Always written: CONTRACT §7 requires an operator-visible trace of every refusal. */
  refusal(code: string, fields: LogFields = {}): LogRecord | null {
    return this.emit("warn", "refusal", { code, ...fields }, false);
  }

  /** Builds the record and writes it. Returns `null` when the line was suppressed. */
  emit(level: LogLevel, event: string, fields: LogFields, suppressed: boolean): LogRecord | null {
    if (suppressed) return null;
    const clean: Record<string, LogField> = {};
    let dropped = 0;
    for (const key of Object.keys(fields).sort()) {
      if (FORBIDDEN_FIELDS.includes(key.toLowerCase())) {
        dropped += 1;
        continue;
      }
      const value = fields[key];
      if (value === undefined) continue;
      clean[key] = typeof value === "string" ? this.scrub(value) : value;
    }
    if (dropped > 0) clean["redactedFields"] = dropped;
    const record: LogRecord = {
      ts: this.clock().toISOString(),
      level,
      event,
      skill: LOG_SKILL,
      fields: clean
    };
    this.sink(
      JSON.stringify({
        ts: record.ts,
        level: record.level,
        event: record.event,
        skill: record.skill,
        ...record.fields
      })
    );
    return record;
  }
}

/**
 * Pulls every secret-shaped string out of a handoff so it can be registered for scrubbing: the bare
 * token form, the `?t=` query form, and the plugin shared secret. Returns them; logs none of them.
 */
export function secretCandidates(handoff: string, extra: readonly (string | undefined)[]): string[] {
  const out: string[] = [];
  const trimmed = handoff.trim();
  if (trimmed !== "" && !/^https?:\/\//i.test(trimmed)) out.push(trimmed);
  if (trimmed !== "") {
    try {
      const url = new URL(trimmed);
      const fromQuery = url.searchParams.get("t");
      if (fromQuery !== null && fromQuery !== "") out.push(fromQuery);
    } catch {
      // Not a URL: the whole string is the token, already pushed above.
    }
  }
  for (const value of extra) if (value !== undefined && value !== "") out.push(value);
  return out;
}

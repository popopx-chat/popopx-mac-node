/**
 * Turning Linger's host arguments into a canonical `NODE_CMD` line, and the operator's settings into
 * one resolved record.
 *
 * The host speaks three loose things — a service that may be an alias (`warroom`), an action that may
 * be any of the node's accepted spellings (`daily`), and a payload that may be an object or already
 * JSON text. The node speaks exactly one strict thing:
 * `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}` with the `EngineKind` raw value and a
 * canonical action name (`Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`, routing table at
 * `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2199-2328`). So this file canonicalises
 * with the shared helpers, renders the canonical line, then hands that line to the shared parser for
 * the verdict. It never accepts a line the parser would reject, and it never decides policy:
 * `assertSendable` in `@popopx/node-bridge` owns that, which is why the lockdown gate cannot be
 * talked around from here.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { readFileSync } from "node:fs";
import { isAbsolute, resolve as resolvePath } from "node:path";

import {
  COMMAND_PREFIX,
  ROUTES,
  SERVICE_IDS,
  assertSendable,
  canonicalAction,
  parseWireLine,
  renderWireLine,
  resolveServiceId,
  type ParseFailureCode,
  type ServiceId,
  type WireCommand
} from "@popopx/node-bridge";

/** What the host may pass as `payload`: raw JSON text, or a value to encode as JSON text. */
export type SkillPayload = string | Record<string, unknown> | readonly unknown[] | number | boolean | null;

export type BuildOutcome =
  | { readonly ok: true; readonly command: WireCommand; readonly line: string }
  | { readonly ok: false; readonly code: ParseFailureCode; readonly reason: string };

export type EncodeOutcome = { readonly ok: true; readonly text: string } | { readonly ok: false; readonly reason: string };

/** `Unknown service identifier "…". Known ids: …`, which is the node's own wording (`TenBusinessEngines.swift:2086-2090`). */
export function knownIds(): string {
  return SERVICE_IDS.join(", ");
}

/** The canonical action names a service routes, for the message that names them back to the host. */
export function canonicalActionsOf(service: ServiceId): readonly string[] {
  return ROUTES[service].canonical;
}

/** The canonical action names this bridge refuses to send for a service, whatever the node would do. */
export function deniedActionsOf(service: ServiceId): readonly string[] {
  return ROUTES[service].denied;
}

/**
 * Encodes the host payload as the raw JSON text the wire line carries. A string is taken verbatim so a
 * host that already serialised its payload is not double-encoded; everything else goes through
 * `JSON.stringify`. An absent payload becomes `{}`: the grammar needs a non-empty payload and the
 * invoke route needs a JSON object (`MacNodeModels.swift:126`, `LocalWebConsoleServer.swift:3875-3879`).
 */
export function payloadText(payload: SkillPayload | undefined): EncodeOutcome {
  if (payload === undefined) return { ok: true, text: "{}" };
  if (typeof payload === "string") {
    if (payload.trim() === "") return { ok: false, reason: "payload is an empty string; pass JSON object text or an object" };
    return { ok: true, text: payload };
  }
  try {
    const text = JSON.stringify(payload);
    if (text === undefined) return { ok: false, reason: "payload is not JSON-serialisable" };
    return { ok: true, text };
  } catch (error) {
    return { ok: false, reason: `payload is not JSON-serialisable: ${(error as Error).name}` };
  }
}

/**
 * The one construction path: alias and spelling resolution first, then the canonical line, then the
 * shared strict parser. Because the line is built from canonical parts, the 1 024-grapheme payload
 * budget is charged against exactly what the node counts (`MacNodeModels.swift:52,129-131`), so an
 * alias costs the host no budget it would not have paid as a canonical id.
 */
export function buildCommand(service: string, action: string, payload?: SkillPayload): BuildOutcome {
  const rawService = service.trim();
  if (rawService === "") return { ok: false, code: "malformedCommand", reason: "empty serviceId" };
  const rawAction = action.trim();
  if (rawAction === "") return { ok: false, code: "emptyAction", reason: "empty action" };

  const serviceId = resolveServiceId(rawService);
  if (serviceId === null) {
    return {
      ok: false,
      code: "unknownService",
      reason: `Unknown service identifier “${rawService.slice(0, 48)}”. Known ids: ${knownIds()}`
    };
  }

  const canonical = canonicalAction(serviceId, rawAction);
  if (canonical === null) {
    return {
      ok: false,
      code: "malformedCommand",
      reason: `unknown action “${rawAction.slice(0, 48)}” for ${serviceId}; canonical actions: ${canonicalActionsOf(serviceId).join(", ")}`
    };
  }

  const encoded = payloadText(payload);
  if (!encoded.ok) return { ok: false, code: "malformedCommand", reason: encoded.reason };

  const parsed = parseWireLine(`${COMMAND_PREFIX}${serviceId}::${canonical}::${encoded.text}`);
  if (!parsed.ok) return { ok: false, code: parsed.code, reason: parsed.reason };
  // The parser canonicalises on its own, so rendering its command back out is the assertion that this
  // package and the shared grammar agree about the spelling that reaches the node.
  return { ok: true, command: parsed.command, line: renderWireLine(parsed.command) };
}

/**
 * The policy gate: `assertSendable` from the barrel, called with the operator's two opt-in inputs.
 * It runs before the console target is resolved, so a refused lockdown has no socket to leak through.
 * This package passes the two flags through and adds nothing: a lockdown needs `allowLockdown: true`
 * *and* a plugin shared secret of at least 16 characters.
 */
export function checkPolicy(command: WireCommand, allowLockdown: boolean, secret: string): void {
  assertSendable(command, { allowLockdown, secret });
}

// MARK: - Operator settings

/** Exactly the keys `config/popopx-bridge.example.json` may carry. Anything else is a hard failure. */
export const CONFIG_KEYS = ["handoff", "timeoutMs", "allowLockdown", "logRefusals"] as const;

export interface ConfigFile {
  readonly handoff: string;
  readonly timeoutMs: number;
  readonly allowLockdown: boolean;
  readonly logRefusals: boolean;
}

export type ConfigOutcome =
  | { readonly ok: true; readonly config: Partial<ConfigFile> }
  | { readonly ok: false; readonly reason: string };

/** `Partial<ConfigFile>` keeps the `readonly` modifiers, so the builder needs a writable twin. */
type ConfigWrite = { -readonly [K in keyof ConfigFile]?: ConfigFile[K] };

/**
 * Reads one JSON config. Strict on purpose: a typo'd key means the operator believes they configured
 * something that does not exist, and ignoring it silently is the worse outcome. Absolute paths and
 * `file:` URLs in `handoff` are refused, because that key holds a bearer secret and must never point
 * at a filesystem location.
 */
export function loadConfigFile(path: string): ConfigOutcome {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    return { ok: false, reason: `config file unreadable: ${(error as Error).message}` };
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(text) as unknown;
  } catch (error) {
    return { ok: false, reason: `config file is not JSON: ${(error as Error).name}` };
  }
  if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) {
    return { ok: false, reason: "config file must hold one JSON object" };
  }

  const source = decoded as Record<string, unknown>;
  for (const key of Object.keys(source)) {
    if (!(CONFIG_KEYS as readonly string[]).includes(key)) {
      return { ok: false, reason: `unknown config key “${key}”; allowed keys: ${CONFIG_KEYS.join(", ")}` };
    }
  }

  const config: ConfigWrite = {};

  const handoff = source["handoff"];
  if (handoff !== undefined) {
    if (typeof handoff !== "string") return { ok: false, reason: "config key handoff must be a string" };
    const trimmed = handoff.trim();
    if (isAbsolute(trimmed) || trimmed.startsWith("file://")) {
      return { ok: false, reason: "config key handoff must be a console URL or a token, never a file path" };
    }
    config.handoff = handoff;
  }

  const timeoutMs = source["timeoutMs"];
  if (timeoutMs !== undefined) {
    if (typeof timeoutMs !== "number" || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 3_600_000) {
      return { ok: false, reason: "config key timeoutMs must be an integer between 1 and 3600000" };
    }
    config.timeoutMs = timeoutMs;
  }

  const allowLockdown = source["allowLockdown"];
  if (allowLockdown !== undefined) {
    if (typeof allowLockdown !== "boolean") {
      return { ok: false, reason: "config key allowLockdown must be a boolean" };
    }
    config.allowLockdown = allowLockdown;
  }

  const logRefusals = source["logRefusals"];
  if (logRefusals !== undefined) {
    if (typeof logRefusals !== "boolean") return { ok: false, reason: "config key logRefusals must be a boolean" };
    config.logRefusals = logRefusals;
  }

  return { ok: true, config };
}

export interface SkillSettings {
  readonly handoff: string;
  readonly env: NodeJS.ProcessEnv;
  readonly timeoutMs: number | undefined;
  readonly allowLockdown: boolean;
  readonly secret: string;
  readonly logRefusals: boolean;
  readonly configPath: string | undefined;
}

export type SettingsOutcome =
  | { readonly ok: true; readonly settings: SkillSettings }
  | { readonly ok: false; readonly reason: string };

export interface SettingsInput {
  readonly handoff?: string;
  readonly env?: NodeJS.ProcessEnv;
  readonly allowLockdown?: boolean;
  readonly secret?: string;
  readonly timeoutMs?: number;
  readonly logRefusals?: boolean;
}

/**
 * Precedence: the explicit call argument, then the config file named by `PPX_SKILL_CONFIG`, then the
 * environment, then the safe default. Safe defaults are `allowLockdown: false` and `logRefusals: true`.
 * An empty handoff is not an error here: `resolveTarget` reads `PPX_CONSOLE_TOKEN` for exactly that
 * case, which is how the handoff the menu bar copies stays out of any file.
 */
export function resolveSettings(input: SettingsInput): SettingsOutcome {
  const env = input.env ?? process.env;
  const configEnv = env["PPX_SKILL_CONFIG"]?.trim() ?? "";
  const configPath = configEnv === "" ? undefined : resolvePath(configEnv);

  let config: Partial<ConfigFile> = {};
  if (configPath !== undefined) {
    const loaded = loadConfigFile(configPath);
    if (!loaded.ok) return { ok: false, reason: loaded.reason };
    config = loaded.config;
  }

  const explicit = input.handoff?.trim() ?? "";
  const fromFile = config.handoff?.trim() ?? "";
  const timeoutMs = input.timeoutMs ?? config.timeoutMs;
  if (timeoutMs !== undefined && (!Number.isInteger(timeoutMs) || timeoutMs < 1)) {
    return { ok: false, reason: `timeoutMs must be a positive integer, got ${String(timeoutMs)}` };
  }

  return {
    ok: true,
    settings: {
      handoff: explicit === "" ? fromFile : explicit,
      env,
      timeoutMs,
      allowLockdown: input.allowLockdown ?? config.allowLockdown ?? false,
      secret: input.secret ?? env["PPX_BRIDGE_SECRET"] ?? "",
      logRefusals: input.logRefusals ?? config.logRefusals ?? true,
      configPath
    }
  };
}

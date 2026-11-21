/**
 * The Linger skill entry point: host arguments in, one typed answer out.
 *
 * `run()` is the whole surface a Linger-shaped host needs, and it is deliberately ordered so that the
 * three cheap, local verdicts happen before anything touches the network:
 *
 *   1. grammar — build the canonical `NODE_CMD` line and let `@popopx/node-bridge` judge it;
 *   2. settings — read the config file, if the operator named one, or fall back to the safe defaults;
 *   3. policy — `assertSendable`, which is what keeps `phantom_sentinel lockdown` from ever reaching a
 *      socket (CONTRACT §7 · `TenBusinessEngines.swift:2118-2123` shows why it must not);
 *   4. target — loopback-only resolution of the handoff (CONTRACT §1, §2);
 *   5. execution — `invokeWithRetry`, so this package never hand-rolls a `fetch` and never invents a
 *      retry broader than "the node demonstrably never received the request".
 *
 * Every failure path returns a typed `LingerSkillOutput`. Nothing here throws at the host, because a
 * skill host that has to catch an exception will render the stack to a user.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { createHash } from "node:crypto";

import {
  BridgeError,
  NodeBridge,
  SERVICE_IDS,
  describeError,
  graphemeCount,
  resolveTarget,
  type BridgeErrorCode,
  type CommandResult,
  type ConsoleTarget,
  type ServiceId,
  type WireCommand
} from "@popopx/node-bridge";

import {
  buildCommand,
  checkPolicy,
  deniedActionsOf,
  resolveSettings,
  type SkillPayload,
  type SkillSettings
} from "./handlers.js";
import { SkillLogger, secretCandidates, type LogField, type LogFields } from "./log.js";

/** The id a host registers this skill under, and the value of `SKILL.md`'s `name:`. */
export const SKILL_NAME = "popopx-mac-node";

/** The arguments the host is expected to supply, in the order `SKILL.md` documents them. */
export const SKILL_INPUT_FIELDS = ["service", "action", "payload", "handoff"] as const;

/** Everything `run()` can report as a failure: the shared vocabulary plus one plugin-level code. */
export type SkillErrorCode = BridgeErrorCode | "badConfig";

export interface LingerSkillInput {
  /** `EngineKind` raw value or one of its aliases, e.g. `shadow_cos` or `warroom`. */
  readonly service: string;
  /** Any spelling the node routes, e.g. `daily`; the canonical name is what gets sent. */
  readonly action: string;
  /** JSON object, or the raw JSON text of one. Omitted means `{}`. */
  readonly payload?: SkillPayload;
  /** Tokenised console URL copied from the node, or a bare token. Empty means read `PPX_CONSOLE_TOKEN`. */
  readonly handoff?: string;
  /** Environment to read instead of `process.env`: `PPX_CONSOLE_TOKEN`, `PPX_SKILL_CONFIG`, `PPX_BRIDGE_SECRET`. */
  readonly env?: NodeJS.ProcessEnv;
  /** Opt-in for the physical lockdown path. Off by default and never implied. */
  readonly allowLockdown?: boolean;
  /** Plugin shared secret of at least 16 characters, required alongside `allowLockdown`. */
  readonly secret?: string;
  /** Per-call timeout in milliseconds; the shared client default is 15 000. */
  readonly timeoutMs?: number;
  /** When false, a refusal record still lands in the log but without the line that caused it. */
  readonly logRefusals?: boolean;
  /** Transport seam for tests and diagnostics. Execution still goes through `ConsoleClient`. */
  readonly fetch?: typeof fetch;
  /** Log seam for tests and diagnostics. Defaults to one JSON line per record on `stderr`. */
  readonly log?: (line: string) => void;
}

export interface LingerSkillSuccess {
  readonly ok: true;
  readonly code: "ok";
  /** The node's headline, so `message` means the same thing on both arms. */
  readonly message: string;
  /** The block a chat-shaped host should show. */
  readonly text: string;
  readonly service: ServiceId;
  readonly action: string;
  /** The canonical wire line this call was built from. */
  readonly line: string;
  /** The engine's own verdict. `ok: true` with `nodeOk: false` means the node answered and refused. */
  readonly nodeOk: boolean;
  readonly engine: string;
  readonly headline: string;
  /** Verbatim: the node already truncates the body at 1 800 characters (`MacNodeModels.swift:1196-1200`). */
  readonly body: string;
  readonly artifacts: readonly string[];
  readonly durationMs: number;
  readonly at: string;
  readonly deterministic: boolean;
  readonly resultId: string;
  readonly commandId: string | null;
  readonly metrics: Readonly<Record<string, unknown>>;
  readonly origin: string;
  readonly tokenFingerprint: string;
}

export interface LingerSkillFailure {
  readonly ok: false;
  readonly code: SkillErrorCode;
  readonly message: string;
  readonly detail?: string;
  readonly text: string;
  readonly service?: string;
  readonly action?: string;
  readonly line?: string;
  readonly origin?: string;
  readonly tokenFingerprint?: string;
}

export type LingerSkillOutput = LingerSkillSuccess | LingerSkillFailure;

/** Context a failure may carry, kept separate so `fail()` cannot overwrite its own discriminants. */
interface FailureExtra {
  readonly line?: string;
  readonly origin?: string;
  readonly tokenFingerprint?: string;
}

/** Settings to judge policy with when the operator's config file could not be read: deny first. */
const SAFE_SETTINGS: SkillSettings = {
  handoff: "",
  env: {},
  timeoutMs: undefined,
  allowLockdown: false,
  secret: "",
  logRefusals: true,
  configPath: undefined
};

const bridgeCache = new Map<string, NodeBridge>();
const transportIds = new WeakMap<object, number>();
let transportSeq = 0;

/** Drops every cached client. Call it after a node restart if you reuse one process. */
export function clearBridgeCache(): void {
  bridgeCache.clear();
}

/** How many nodes this process is holding a client for; a leak check, not a feature. */
export function cachedBridgeCount(): number {
  return bridgeCache.size;
}

/**
 * A one-way digest, used only as an in-memory cache key. A restart mints a new token of the same
 * length, so the length alone cannot tell two handoffs apart, and the raw token must not end up in a
 * key that a diagnostic dump might print.
 */
function digest(value: string): string {
  return createHash("sha256").update(value).digest("base64url").slice(0, 16);
}

function transportTag(fetchImpl: typeof fetch | undefined): string {
  if (fetchImpl === undefined) return "global";
  const seen = transportIds.get(fetchImpl);
  if (seen !== undefined) return String(seen);
  const id = (transportSeq += 1);
  transportIds.set(fetchImpl, id);
  return String(id);
}

/**
 * One client per (node, handoff, mode). The cache is what makes the single-in-flight rule real: a
 * second concurrent `run()` for the same node hits the same `ConsoleClient`, and its serialiser answers
 * `inFlightLimit` instead of queueing (CONTRACT §8).
 */
function bridgeFor(
  target: ConsoleTarget,
  settings: SkillSettings,
  fetchImpl: typeof fetch | undefined
): { readonly bridge: NodeBridge; readonly created: boolean } {
  const key = [
    target.origin,
    digest(target.token),
    String(settings.timeoutMs ?? "default"),
    settings.allowLockdown ? "lockdown-opt-in" : "lockdown-off",
    settings.secret === "" ? "no-secret" : digest(settings.secret),
    transportTag(fetchImpl)
  ].join("|");

  const cached = bridgeCache.get(key);
  if (cached !== undefined) return { bridge: cached, created: false };
  const bridge = new NodeBridge({
    handoff: settings.handoff,
    env: settings.env,
    ...(settings.timeoutMs === undefined ? {} : { timeoutMs: settings.timeoutMs }),
    allowLockdown: settings.allowLockdown,
    secret: settings.secret,
    ...(fetchImpl === undefined ? {} : { fetchImpl })
  });
  bridgeCache.set(key, bridge);
  return { bridge, created: true };
}

/** The block a chat-shaped host shows. The body is not re-truncated: the node already did that. */
export function renderResult(command: WireCommand, result: CommandResult): string {
  const verdict = result.ok ? "ok" : "refused";
  const lines: string[] = [`${verdict} · ${command.serviceId} · ${command.action}`, result.headline];
  if (result.body !== "") lines.push(result.body);
  for (const artifact of result.artifacts) lines.push(`artifact ${artifact}`);
  lines.push(`${result.durationMs} ms`);
  return lines.join("\n");
}

function failureText(code: string, message: string, detail: string | undefined): string {
  return detail === undefined || detail === "" ? `${code} · ${message}` : `${code} · ${message}\n${detail}`;
}

function failureFields(error: BridgeError, settings: SkillSettings): LogFields {
  const fields: Record<string, LogField> = { code: error.code, message: error.message };
  if (error.status !== undefined) fields["status"] = error.status;
  if (error.detail !== undefined && error.detail !== "") fields["detail"] = error.detail;
  fields["outcomeUnknown"] = error.outcomeUnknown;
  fields["allowLockdown"] = settings.allowLockdown;
  return fields;
}

/**
 * Runs one command against one node. Never throws: an unexpected non-`BridgeError` comes back as
 * `badResponse` with the original name and message, because that is the honest label for "we asked and
 * did not get a typed answer".
 */
export async function run(input: LingerSkillInput): Promise<LingerSkillOutput> {
  const env = input.env ?? process.env;
  const logger = new SkillLogger({
    sink: input.log,
    quiet: env["PPX_SKILL_LOG"] === "silent",
    redact: secretCandidates(input.handoff ?? "", [env["PPX_CONSOLE_TOKEN"], env["PPX_BRIDGE_SECRET"]])
  });

  // Until a command exists the host's own spelling is all there is to echo; after that the ids below
  // are the canonical ones, so a refusal names the engine the node would actually have run.
  let echoed = { service: input.service, action: input.action };
  // `detail` is only ever the node's or the bridge's own explanation: never a token, never a payload.
  const fail = (
    code: SkillErrorCode,
    message: string,
    detail?: string,
    extra: FailureExtra = {}
  ): LingerSkillFailure => ({
    ok: false,
    code,
    message,
    ...(detail === undefined || detail === "" ? {} : { detail }),
    text: failureText(code, message, detail),
    ...echoed,
    ...extra
  });

  // 1 · grammar. Nothing is decided here that `parseWireLine` does not decide too.
  const built = buildCommand(input.service, input.action, input.payload);
  if (!built.ok) {
    logger.refusal(built.code, { ...echoed, reason: built.reason, reasonChars: built.reason.length });
    return fail(built.code, built.reason);
  }
  const command = built.command;
  const line = built.line;
  echoed = { service: command.serviceId, action: command.action };

  // 2 · settings. A broken config file must not turn into a permissive default.
  const outcome = resolveSettings(input);
  const settings = outcome.ok ? outcome.settings : SAFE_SETTINGS;
  if (outcome.ok) {
    for (const candidate of secretCandidates(settings.handoff, [settings.env["PPX_CONSOLE_TOKEN"]])) {
      logger.addRedaction(candidate);
    }
  }

  // 3 · policy, with the safe settings when the config could not be read.
  try {
    checkPolicy(command, settings.allowLockdown, settings.secret);
  } catch (error) {
    if (error instanceof BridgeError) {
      const fields: Record<string, LogField> = { ...failureFields(error, settings), line };
      if (!settings.logRefusals) {
        delete fields["line"];
        fields["lineOmitted"] = "logRefusals=false";
      }
      logger.refusal(error.code, fields);
      return fail(
        error.code,
        error.message,
        [
          error.detail,
          `blocked canonical actions for ${command.serviceId}: ${deniedActionsOf(command.serviceId).join(", ")}`
        ]
          .filter((part): part is string => part !== undefined && part !== "")
          .join("\n"),
        { line }
      );
    }
    logger.error("policyCheckFailed", { ...echoed, detail: describeError(error) });
    return fail("badResponse", describeError(error), undefined, { line });
  }

  if (!outcome.ok) {
    logger.error("configRejected", { ...echoed, detail: outcome.reason, configPath: env["PPX_SKILL_CONFIG"] ?? "unset" });
    return fail(
      "badConfig",
      outcome.reason,
      `config path: ${env["PPX_SKILL_CONFIG"] ?? "unset"}`,
      { line }
    );
  }

  // 4 · target. Loopback only, one port, and the token never leaves the process unsent.
  let target: ConsoleTarget;
  try {
    target = resolveTarget(settings.handoff, settings.env);
  } catch (error) {
    if (error instanceof BridgeError) {
      logger.refusal(error.code, failureFields(error, settings));
      return fail(error.code, error.message, error.detail, { line });
    }
    logger.error("targetFailed", { ...echoed, detail: describeError(error) });
    return fail("nonLoopbackTarget", describeError(error), undefined, { line });
  }

  // 5 · execution. One client per node, so the single in-flight slot is shared, not simulated.
  let bridge: NodeBridge;
  try {
    bridge = bridgeFor(target, settings, input.fetch).bridge;
  } catch (error) {
    const code: SkillErrorCode = error instanceof BridgeError ? error.code : "badResponse";
    logger.error("bridgeInitFailed", { ...echoed, code, detail: describeError(error) });
    return fail(code, describeError(error), undefined, { line, origin: target.origin });
  }

  const fingerprint = bridge.tokenFingerprint;
  logger.info("invoke", {
    service: command.serviceId,
    action: command.action,
    rawAction: command.rawAction,
    line,
    origin: target.origin,
    tokenFingerprint: fingerprint,
    payloadGraphemes: graphemeCount(command.payload),
    // 15 000 ms is the shared client's own default, restated so a log line is self-explanatory.
    timeoutMs: settings.timeoutMs ?? 15_000
  });

  try {
    const result = await bridge.invokeWithRetry(command);
    logger.info("result", {
      service: command.serviceId,
      action: command.action,
      nodeOk: result.ok,
      engine: result.engine,
      headline: result.headline,
      bodyUtf16: result.body.length,
      artifacts: result.artifacts.length,
      durationMs: result.durationMs,
      origin: target.origin,
      tokenFingerprint: fingerprint
    });
    return {
      ok: true,
      code: "ok",
      message: result.headline,
      text: renderResult(command, result),
      service: command.serviceId,
      action: command.action,
      line,
      nodeOk: result.ok,
      engine: result.engine,
      headline: result.headline,
      body: result.body,
      artifacts: result.artifacts,
      durationMs: result.durationMs,
      at: result.at,
      deterministic: result.deterministic,
      resultId: result.id,
      commandId: result.commandID,
      metrics: result.metrics,
      origin: target.origin,
      tokenFingerprint: fingerprint
    };
  } catch (error) {
    if (error instanceof BridgeError) {
      logger.error("commandFailed", { ...failureFields(error, settings), service: command.serviceId, tokenFingerprint: fingerprint });
      return fail(error.code, error.message, error.detail, { line, origin: target.origin, tokenFingerprint: fingerprint });
    }
    logger.error("commandFailed", { ...echoed, code: "badResponse", detail: describeError(error) });
    return fail("badResponse", describeError(error), undefined, { line, origin: target.origin, tokenFingerprint: fingerprint });
  }
}

/** Every service id this skill can name, for a host that builds its own picker. */
export function services(): readonly ServiceId[] {
  return SERVICE_IDS;
}

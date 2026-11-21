/**
 * The wire grammar of `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}`, mirrored from
 * `NodeWire.parseCommand` in `Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`, plus the
 * routing table mirrored from `TenBusinessEngines.swift:2151-2328`.
 *
 * Three details are easy to get wrong and are the reason this file exists rather than a thin regex:
 *   1. Swift counts `Character`s, which are grapheme clusters. `String.length` in JavaScript counts
 *      UTF-16 units, so the 1 024 budget would disagree with the node on any CJK or emoji payload.
 *      `graphemeCount` uses the built-in `Intl.Segmenter` — no dependency, same verdict.
 *   2. Exactly two `::` are consumed. A payload containing `::` must survive, so splitting cannot use
 *      `String.split`.
 *   3. `engine(for:)` accepts aliases but `parseCommand` does not: `warroom` is a valid id downstream
 *      and an invalid id on the wire. The bridge canonicalises first, then validates, so it can accept
 *      the alias without pretending the wire allows it.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { BridgeError } from "./errors.js";

export const COMMAND_PREFIX = "::popopx_sys::NODE_CMD::";
export const SEGMENT_COUNT = 3;
export const MAX_SIGNAL_PAYLOAD_CHARACTERS = 1024;
export const DEFAULT_CONSOLE_HOST = "127.0.0.1";
export const DEFAULT_CONSOLE_PORT = 18920;
export const CONSOLE_TOKEN_HEADER = "X-PPX-Token";

/** `EngineKind.rawValue`, `MacNodeModels.swift:1207-1217`. */
export const SERVICE_IDS = [
  "shadow_cos",
  "zero_trust_warroom",
  "zerotrace_studio",
  "solo_autopilot",
  "edge_compute_mesh",
  "morning_tv",
  "phantom_sentinel",
  "chrono_ark",
  "health_sentinel",
  "creator_paywall_hub"
] as const;

export type ServiceId = (typeof SERVICE_IDS)[number];

/** `TenBusinessEngines.swift:2151-2170`, with the separator and case folding of `engine(for:)`. */
const SERVICE_ALIASES: Record<string, ServiceId> = {
  warroom: "zero_trust_warroom",
  zero_trust: "zero_trust_warroom",
  gop_watermark: "zero_trust_warroom",
  studio: "zerotrace_studio",
  zero_trace: "zerotrace_studio",
  solo: "solo_autopilot",
  autopilot: "solo_autopilot",
  mesh: "edge_compute_mesh",
  edge_mesh: "edge_compute_mesh",
  compute_mesh: "edge_compute_mesh",
  tv: "morning_tv",
  morning: "morning_tv",
  sentinel: "phantom_sentinel",
  lockdown: "phantom_sentinel",
  ark: "chrono_ark",
  time_lock: "chrono_ark",
  health: "health_sentinel",
  paywall: "creator_paywall_hub",
  creator: "creator_paywall_hub",
  cos: "shadow_cos",
  chief_of_staff: "shadow_cos"
};

export interface RouteTable {
  readonly canonical: readonly string[];
  /** Canonical names the bridge refuses to send, whatever the node would do with them. */
  readonly denied: readonly string[];
  /** Every accepted spelling, canonical names included, mapped to its canonical name. */
  readonly aliases: Readonly<Record<string, string>>;
}

type ServiceSpec = {
  readonly canonical: readonly string[];
  /** One group per canonical action: `[canonical, ...acceptedAliases]`. */
  readonly groups: readonly (readonly string[])[];
  /** Same shape as `groups`, but the bridge blocks the call instead of making it. */
  readonly denied?: readonly (readonly string[])[];
};

const SPEC: Readonly<Record<ServiceId, ServiceSpec>> = {
  shadow_cos: {
    canonical: ["briefing", "negotiation_prompt"],
    groups: [["briefing", "brief", "run", "daily", "daily_brief", "generate"],
             ["negotiation_prompt", "negotiation", "tactics", "prompt"]]
  },
  zero_trust_warroom: {
    canonical: ["assign", "embed", "trace", "registry"],
    groups: [["assign", "register", "queue_assign"],
             ["embed", "mark", "distribute"],
             ["trace", "extract", "identify", "decode"],
             ["registry", "status"]]
  },
  zerotrace_studio: {
    canonical: ["process", "strip", "anchor", "shred"],
    groups: [["process", "run", "ingest", "sanitize", "sanitise"],
             ["strip", "clean", "metadata"],
             ["anchor", "briefing_clip", "broadcast"],
             ["shred", "destroy"]]
  },
  solo_autopilot: {
    canonical: ["run", "script"],
    groups: [["run", "generate", "video", "clip"], ["script", "copy"]]
  },
  edge_compute_mesh: {
    canonical: ["status", "offer", "poll", "enable", "settle"],
    groups: [["status", "summary"],
             ["offer", "accept", "execute", "run"],
             ["poll", "drain"],
             ["enable", "sharing"],
             ["settle"]]
  },
  morning_tv: {
    canonical: ["broadcast", "digest", "scheduled", "schedule"],
    groups: [["broadcast", "run", "tv"],
             ["digest", "headlines", "feeds"],
             ["scheduled", "fire", "on_time"],
             ["schedule", "next"]]
  },
  phantom_sentinel: {
    canonical: ["status"],
    groups: [["status", "probe"]],
    // `TenBusinessEngines.swift:2282` — every one of these runs `lockdown` on the node.
    denied: [["lockdown", "lock", "lock_all", "sentinel", "\u{1F512}"]]
  },
  chrono_ark: {
    canonical: ["seal", "list", "unseal", "heartbeat", "check", "reveal"],
    groups: [["seal", "lock", "store"],
             ["list", "vaults", "status"],
             ["unseal", "open", "recover"],
             ["heartbeat", "ping", "alive"],
             ["check", "watch", "release_check"],
             ["reveal", "dir", "folder"]]
  },
  health_sentinel: {
    canonical: ["read", "binaural"],
    groups: [["read", "report", "parse", "interpret"], ["binaural", "tone", "sleep", "wav"]]
  },
  creator_paywall_hub: {
    canonical: ["verify", "grant", "claim", "status"],
    groups: [["verify", "ticket", "admit"],
             ["grant", "deliver", "drop", "distribute"],
             ["claim", "red_packet", "redpacket"],
             ["status", "ledger"]]
  }
};

/** Built once from `SPEC` so there is exactly one transcription of the node's dispatch table. */
export const ROUTES: Readonly<Record<ServiceId, RouteTable>> = buildRoutes(SPEC);

function buildRoutes(spec: Readonly<Record<ServiceId, ServiceSpec>>): Record<ServiceId, RouteTable> {
  const out = {} as Record<ServiceId, RouteTable>;
  for (const id of SERVICE_IDS) {
    const table = spec[id];
    const aliases: Record<string, string> = {};
    for (const group of table.groups) {
      const canonical = group[0];
      if (canonical === undefined) continue;
      for (const spelling of group) aliases[spelling] = canonical;
    }
    const denied: string[] = [];
    for (const group of table.denied ?? []) {
      const canonical = group[0];
      if (canonical === undefined) continue;
      denied.push(canonical);
      for (const spelling of group) aliases[spelling] = canonical;
    }
    out[id] = { canonical: table.canonical, denied, aliases };
  }
  return out;
}

export type ParseFailureCode = "malformedCommand" | "unknownService" | "emptyAction" | "payloadBudget";

export type ParseResult =
  | { readonly ok: true; readonly command: WireCommand }
  | { readonly ok: false; readonly code: ParseFailureCode; readonly reason: string };

export interface WireCommand {
  /** Service as it arrived on the wire, before canonicalisation. */
  readonly rawServiceId: string;
  readonly serviceId: ServiceId;
  /** Action as it arrived, trimmed only. */
  readonly rawAction: string;
  /** Canonical action name, after `normaliseAction` and the routing table. */
  readonly action: string;
  readonly payload: string;
  readonly payloadObject: Readonly<Record<string, unknown>>;
  /** True when the canonical action is blocked by the bridge. */
  readonly denied: boolean;
  readonly invokeBody: { readonly kind: ServiceId; readonly action: string; readonly payload: object };
}

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** Counts grapheme clusters, which is what `String.count` means in Swift. */
export function graphemeCount(text: string): number {
  return Array.from(segmenter.segment(text)).length;
}

/** `engine(for:)` folding: trim, lowercase, `-` becomes `_`. */
export function normaliseServiceId(raw: string): string {
  return raw.trim().toLowerCase().replaceAll("-", "_");
}

/** `normalisedAction`: trim, lowercase, spaces become `_`. */
export function normaliseAction(raw: string): string {
  return raw.trim().toLowerCase().replaceAll(" ", "_");
}

export function resolveServiceId(raw: string): ServiceId | null {
  const normalised = normaliseServiceId(raw);
  if ((SERVICE_IDS as readonly string[]).includes(normalised)) return normalised as ServiceId;
  return SERVICE_ALIASES[normalised] ?? null;
}

export function canonicalAction(service: ServiceId, action: string): string | null {
  return ROUTES[service].aliases[normaliseAction(action)] ?? null;
}

/**
 * Strict mirror of `NodeWire.parseCommand`. Accepts the prefix only, requires three segments,
 * rejects an empty serviceId, action or payload, rejects an unknown engine id and enforces the
 * 1 024 grapheme budget with the two leading segments charged.
 */
export function parseWireLine(line: string): ParseResult {
  const trimmed = line.trim();
  if (!trimmed.startsWith(COMMAND_PREFIX)) {
    return { ok: false, code: "malformedCommand", reason: "missing ::popopx_sys::NODE_CMD:: prefix" };
  }
  const body = trimmed.slice(COMMAND_PREFIX.length);
  const first = body.indexOf("::");
  const second = first < 0 ? -1 : body.indexOf("::", first + 2);
  if (second < 0) {
    return { ok: false, code: "malformedCommand", reason: "fewer than 3 segments" };
  }
  const rawServiceId = body.slice(0, first).trim();
  const rawAction = body.slice(first + 2, second).trim();
  const payload = body.slice(second + 2);

  if (rawServiceId === "") return { ok: false, code: "malformedCommand", reason: "empty serviceId" };
  if (rawAction === "") return { ok: false, code: "emptyAction", reason: "empty action" };
  if (payload === "") return { ok: false, code: "malformedCommand", reason: "empty payload" };

  const serviceId = resolveServiceId(rawServiceId);
  if (serviceId === null) {
    return { ok: false, code: "unknownService", reason: `no such service: ${rawServiceId.slice(0, 32)}` };
  }

  const used = graphemeCount(rawServiceId) + graphemeCount(rawAction) + 2;
  const budget = MAX_SIGNAL_PAYLOAD_CHARACTERS - used;
  if (graphemeCount(payload) > budget) {
    return { ok: false, code: "payloadBudget", reason: `payload exceeds ${budget} graphemes` };
  }

  const action = canonicalAction(serviceId, rawAction);
  if (action === null) {
    return { ok: false, code: "malformedCommand", reason: `unknown action for ${serviceId}` };
  }

  let payloadObject: Record<string, unknown>;
  try {
    const decoded: unknown = JSON.parse(payload);
    if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) {
      return {
        ok: false,
        code: "malformedCommand",
        reason: "payload must be a JSON object: /api/engine/invoke decodes it as a dictionary"
      };
    }
    payloadObject = decoded as Record<string, unknown>;
  } catch (error) {
    return {
      ok: false,
      code: "malformedCommand",
      reason: `payload is not JSON: ${(error as Error).name}`
    };
  }

  return {
    ok: true,
    command: {
      rawServiceId,
      serviceId,
      rawAction,
      action,
      payload,
      payloadObject,
      denied: ROUTES[serviceId].denied.includes(action),
      invokeBody: { kind: serviceId, action, payload: payloadObject }
    }
  };
}

/** Wraps a parsed command back into the canonical wire line, using the canonical spelling. */
export function renderWireLine(command: WireCommand): string {
  return `${COMMAND_PREFIX}${command.serviceId}::${command.action}::${command.payload}`;
}

export interface PolicyOptions {
  readonly allowLockdown?: boolean;
  readonly secret?: string;
}

/**
 * The bridge-side rule from CONTRACT §7: a lockdown never leaves the process unless the operator
 * opted in *and* presented the plugin secret. This runs before any socket is opened, so a refused
 * command cannot reach the node even by accident, and the reason is returned as a distinct code so
 * a caller cannot mistake it for a transport failure.
 */
export function assertSendable(command: WireCommand, options: PolicyOptions): void {
  if (!command.denied) return;
  if (options.allowLockdown !== true) {
    throw new BridgeError(
      "lockdownDenied",
      `refused to send ${command.serviceId}::${command.action}`,
      { detail: "set allowLockdown: true only after reading integrations/CONTRACT.md section 7" }
    );
  }
  const secret = options.secret ?? "";
  if (secret.length < 16) {
    throw new BridgeError(
      "secretRequired",
      "lockdown requires a plugin shared secret of at least 16 characters",
      { detail: "supply it with PPX_BRIDGE_SECRET, never in a committed file" }
    );
  }
}

export function listServices(): readonly {
  readonly id: ServiceId;
  readonly actions: readonly string[];
  readonly denied: readonly string[];
}[] {
  return SERVICE_IDS.map((id) => ({
    id,
    actions: ROUTES[id].canonical,
    denied: ROUTES[id].denied
  }));
}

/**
 * `@popopx/openclaw-skill` - the OpenClaw-shaped plugin that exposes the POPOPX Mac Node console as
 * ten tools, one per business engine.
 *
 * The host is not a dependency of this package, so `OpenClawApi` below is the minimum structural
 * type a host has to satisfy: a tool registry, an optional logger, optional operator configuration.
 * Everything that decides what goes on the wire lives in `@popopx/node-bridge` and in
 * `./handlers/tenServicesRouter.js`; this file only adapts the host's call shape to that router.
 *
 * Two properties are worth stating where the code is, not only in the contract: the tool enums are
 * generated from the kernel's routing table, so a host cannot be offered an action the node does not
 * route; and `phantom_sentinel` is offered as a report-only tool, with `lockdown` named in
 * `meta.deniedActions` and in `openclaw.plugin.json` rather than silently dropped
 * (`integrations/CONTRACT.md` §7 · 第 7 节).
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { ROUTES, SERVICE_IDS, type ServiceId } from "@popopx/node-bridge";

import { BridgeLogger } from "./log.js";
import {
  TenServicesRouter,
  buildToolDefinitions,
  type RouterOptions,
  type ServiceToolDefinition,
  type ToolResult
} from "./handlers/tenServicesRouter.js";

export const PLUGIN_ID = "com.popopx.node-bridge.openclaw";
export const PLUGIN_NAME = "POPOPX Mac Node bridge";
export const PLUGIN_VERSION = "1.0.1";
/** The one port the node listens on, loopback only (CONTRACT §1 · 第 1 节). */
export const CONSOLE_ORIGIN = "http://127.0.0.1:18920";

export const pluginMeta = {
  id: PLUGIN_ID,
  name: PLUGIN_NAME,
  version: PLUGIN_VERSION,
  description:
    "Ten POPOPX Mac Node services as OpenClaw tools, over the node's own loopback console. No new port, no WebSocket, no credential on disk.",
  entry: "dist/src/index.js",
  license: "AGPL-3.0-only",
  console: CONSOLE_ORIGIN,
  services: SERVICE_IDS,
  /** Spelled out instead of hidden, so an operator can ask the plugin what it refuses and get a true answer. */
  deniedActions: deniedActions()
} as const;

export type PluginMeta = typeof pluginMeta;

/** The tool record a host registers. Structural on purpose: any host with these three fields works. */
export interface OpenClawTool {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: Readonly<Record<string, unknown>>;
}

export type OpenClawToolHandler = (input: unknown) => Promise<ToolResult>;

/** Operator configuration, whatever shape the host keeps it in. Nothing here is a token. */
export interface OpenClawPluginConfig {
  /** A tokenised console URL or a bare token; when absent, `PPX_CONSOLE_TOKEN` is the handoff. */
  readonly handoff?: string;
  readonly env?: NodeJS.ProcessEnv;
  /** Off by default and refused by `deploy/install.sh` when on; see CONTRACT §7 · 第 7 节. */
  readonly allowLockdown?: boolean;
  /** Read from `PPX_BRIDGE_SECRET` in practice, never stored in a manifest. */
  readonly secret?: string;
  readonly timeoutMs?: number;
  readonly fetchImpl?: typeof fetch;
  readonly logger?: BridgeLogger;
}

/** The whole of the host surface this plugin uses. */
export interface OpenClawApi {
  registerTool(tool: OpenClawTool, handler: OpenClawToolHandler): void;
  /** Optional host log channel; the plugin's own one-line JSON logger is always used too. */
  log?(line: string): void;
  readonly config?: OpenClawPluginConfig;
}

export interface PluginRegistration {
  readonly tools: readonly ServiceToolDefinition[];
  readonly router: TenServicesRouter;
  readonly deniedActions: readonly string[];
}

/**
 * Registers one tool per service and returns what was registered, so a host - or the test suite -
 * can see the refusal list without reading the manifest file.
 */
export function register(api: OpenClawApi): PluginRegistration {
  const config = api.config ?? {};
  const router = new TenServicesRouter(routerOptionsFrom(config));
  const tools = buildToolDefinitions();
  for (const definition of tools) {
    const service = serviceOfTool(definition.name);
    api.registerTool(definition, toolHandler(router, service));
    api.log?.(`registered ${definition.name} -> ${service}`);
  }
  return { tools, router, deniedActions: deniedActions() };
}

function toolHandler(router: TenServicesRouter, service: ServiceId): OpenClawToolHandler {
  return async (input: unknown): Promise<ToolResult> => {
    if (isRecord(input)) {
      const named = typeof input["service"] === "string" ? input["service"] : service;
      return await router.call(named, input["action"], input["payload"]);
    }
    // A host that sends the action as a bare string still gets a typed result, not a crash.
    return await router.call(service, input, undefined);
  };
}

function routerOptionsFrom(config: OpenClawPluginConfig): RouterOptions {
  return {
    ...(config.handoff === undefined ? {} : { handoff: config.handoff }),
    ...(config.env === undefined ? {} : { env: config.env }),
    ...(config.allowLockdown === undefined ? {} : { allowLockdown: config.allowLockdown }),
    ...(config.secret === undefined ? {} : { secret: config.secret }),
    ...(config.timeoutMs === undefined ? {} : { timeoutMs: config.timeoutMs }),
    ...(config.fetchImpl === undefined ? {} : { fetchImpl: config.fetchImpl }),
    ...(config.logger === undefined ? {} : { logger: config.logger })
  };
}

/** `popopx_zero_trust_warroom` -> `zero_trust_warroom`; the prefix is the only naming rule here. */
export function serviceOfTool(name: string): ServiceId {
  const bare = name.startsWith("popopx_") ? name.slice("popopx_".length) : name;
  const found = SERVICE_IDS.find((id) => id === bare);
  if (found === undefined) throw new TypeError(`not a POPOPX tool name: ${name}`);
  return found;
}

function deniedActions(): readonly string[] {
  const out: string[] = [];
  for (const id of SERVICE_IDS) {
    for (const action of ROUTES[id].denied) out.push(`${id}:${action}`);
  }
  return out;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export const plugin = { meta: pluginMeta, register };

export { TenServicesRouter, buildToolDefinitions, tableAllowedActions } from "./handlers/tenServicesRouter.js";
export type {
  RouterOptions,
  ServiceToolDefinition,
  ToolCode,
  ToolResult
} from "./handlers/tenServicesRouter.js";
export { BridgeLogger, REDACTED } from "./log.js";
export type { LogEntry, LogFields, LogLevel, LoggerOptions } from "./log.js";

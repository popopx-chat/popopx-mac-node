/**
 * Router and manifest tests, all against a fake `fetch`, with no node running.
 *
 * The claims worth grading are the ones a plugin can get wrong quietly: that an alias the host
 * sends becomes the canonical spelling on the wire, that a lockdown refusal costs zero network
 * calls, that a rejected token is never resent, that a refused connection is resent exactly once,
 * that the 1 024 budget is counted in grapheme clusters like Swift counts them, and that the
 * manifest an operator installs describes the routing table the kernel actually exports rather than
 * a copy of it that can drift.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  COMMAND_PREFIX,
  ROUTES,
  SERVICE_IDS,
  graphemeCount,
  type CommandResult,
  type ServiceId
} from "@popopx/node-bridge";

import {
  BridgeLogger,
  REDACTED,
  PLUGIN_VERSION,
  TenServicesRouter,
  buildToolDefinitions,
  plugin,
  tableAllowedActions
} from "../src/index.js";

const TOKEN = "ZqTestConsoleToken0123456789ab";
const HANDOFF = `http://127.0.0.1:18920/?t=${TOKEN}`;
const SECRET = "0123456789abcdef";

interface Call {
  readonly url: string;
  readonly method: string;
  readonly headers: Record<string, string>;
  readonly body?: string;
}

function packageRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (;;) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate) && readFileSync(candidate, "utf8").includes("@popopx/openclaw-skill")) return dir;
    const parent = dirname(dir);
    if (parent === dir) throw new Error("could not find the package root above the test file");
    dir = parent;
  }
}

const ROOT = packageRoot();

function resultFixture(over: Partial<CommandResult> = {}): CommandResult {
  return {
    id: "r-1",
    commandID: "c-1",
    engine: "shadow_cos",
    ok: true,
    deterministic: false,
    headline: "briefing ready",
    body: "line one",
    artifacts: ["/tmp/briefing.md"],
    durationMs: 42,
    at: "2026-11-21T09:10:11Z",
    metrics: { unknownAction: false },
    ...over
  };
}

const jsonResponse = (payload: unknown, status = 200): Response =>
  new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });

const textResponse = (text: string, status = 200): Response =>
  new Response(text, { status, headers: { "content-type": "text/plain" } });

function refusedConnection(): TypeError {
  const cause = Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:18920"), {
    code: "ECONNREFUSED",
    errno: -61,
    syscall: "connect"
  });
  return Object.assign(new TypeError("fetch failed"), { cause });
}

interface HarnessOptions {
  readonly handler?: (call: Call, index: number) => Response | Promise<Response>;
  readonly handoff?: string;
  readonly env?: NodeJS.ProcessEnv;
  readonly allowLockdown?: boolean;
  readonly secret?: string;
}

function harness(options: HarnessOptions = {}) {
  const calls: Call[] = [];
  const logs: string[] = [];
  const handler = options.handler ?? (() => jsonResponse(resultFixture()));
  const fetchImpl = (async (input: string | URL, init?: RequestInit): Promise<Response> => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers ?? {}).forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    const call: Call = {
      url: String(input),
      method: String(init?.method ?? "GET").toUpperCase(),
      headers,
      ...(typeof init?.body === "string" ? { body: init.body } : {})
    };
    calls.push(call);
    return await handler(call, calls.length - 1);
  }) as unknown as typeof fetch;

  const logger = new BridgeLogger({ sink: (line: string) => logs.push(line) });
  const router = new TenServicesRouter({
    handoff: options.handoff ?? HANDOFF,
    env: options.env ?? {},
    fetchImpl,
    logger,
    ...(options.allowLockdown === undefined ? {} : { allowLockdown: options.allowLockdown }),
    ...(options.secret === undefined ? {} : { secret: options.secret })
  });
  const events = (): readonly { event: string; level: string }[] =>
    logs.map((line) => JSON.parse(line) as { event: string; level: string });
  return { router, calls, logs, events, logger };
}

function invokeBody(call: Call | undefined): Record<string, unknown> {
  assert.ok(call?.body, "the call must carry a body");
  return JSON.parse(call.body) as Record<string, unknown>;
}

/**
 * What the host sends, and what the node must therefore receive. Every row starts from a spelling
 * a human would type and ends at the canonical `EngineKind` rawValue plus the canonical action,
 * because that is the whole job of this handler.
 */
const ROUTING: readonly { readonly service: string; readonly action: string; readonly kind: ServiceId; readonly canonical: string }[] = [
  { service: "cos", action: "daily", kind: "shadow_cos", canonical: "briefing" },
  { service: "warroom", action: "queue_assign", kind: "zero_trust_warroom", canonical: "assign" },
  { service: "studio", action: "clean", kind: "zerotrace_studio", canonical: "strip" },
  { service: "solo", action: "generate", kind: "solo_autopilot", canonical: "run" },
  { service: "mesh", action: "drain", kind: "edge_compute_mesh", canonical: "poll" },
  { service: "tv", action: "fire", kind: "morning_tv", canonical: "scheduled" },
  { service: "sentinel", action: "probe", kind: "phantom_sentinel", canonical: "status" },
  { service: "ark", action: "vaults", kind: "chrono_ark", canonical: "list" },
  { service: "health", action: "interpret", kind: "health_sentinel", canonical: "read" },
  { service: "paywall", action: "redpacket", kind: "creator_paywall_hub", canonical: "claim" }
];

test("all ten services reach the canonical service id and canonical action", async () => {
  for (const row of ROUTING) {
    const { router, calls } = harness();
    const result = await router.call(row.service, row.action, { note: "one" });
    assert.equal(result.ok, true, `${row.service} ${row.action}: ${result.message ?? ""}`);
    assert.equal(calls.length, 1, `${row.service} ${row.action} must be sent once`);
    assert.equal(calls[0]?.url, "http://127.0.0.1:18920/api/engine/invoke");
    assert.deepEqual(invokeBody(calls[0]), {
      kind: row.kind,
      action: row.canonical,
      payload: { note: "one" }
    });
    assert.equal(calls[0]?.headers["x-ppx-token"], TOKEN);
  }
});

test("the node's reply is carried back as a typed result", async () => {
  const { router } = harness({
    handler: () =>
      jsonResponse(resultFixture({ headline: "watermark embedded", body: "report.pdf", durationMs: 17 }))
  });
  const result = await router.call("warroom", "mark", { file: "report.pdf" });
  assert.deepEqual(result, {
    ok: true,
    headline: "watermark embedded",
    body: "report.pdf",
    artifacts: ["/tmp/briefing.md"],
    durationMs: 17
  });
});

test("an engine that says no is reported as engineRefused, not as a transport failure", async () => {
  const { router, events } = harness({
    handler: () => jsonResponse(resultFixture({ ok: false, headline: "引擎已关闭 · studio is switched off" }))
  });
  const result = await router.call("studio", "process", {});
  assert.equal(result.ok, false);
  assert.equal(result.code, "engineRefused");
  assert.match(String(result.headline), /switched off/);
  assert.ok(events().some((entry) => entry.event === "engineRefused"));
});

test("an unknown action is refused locally, with the canonical names, and never sent", async () => {
  const { router, calls } = harness();
  const result = await router.call("zero_trust_warroom", "assign_everyone", {});
  assert.equal(calls.length, 0);
  assert.equal(result.code, "unknownAction");
  assert.match(String(result.message), /assign, embed, trace, registry/);
  assert.match(String(result.message), /queue_assign/, "the other accepted spellings help the host correct itself");
});

test("an unknown service is refused with the real id list", async () => {
  const { router, calls } = harness();
  const result = await router.call("popopx_telegram_bot", "status", {});
  assert.equal(calls.length, 0);
  assert.equal(result.code, "unknownService");
  for (const id of SERVICE_IDS) assert.match(String(result.message), new RegExp(id));
});

test("the empty action the node treats as a default is refused, not guessed", async () => {
  for (const spelling of ["", "  ", "\t"]) {
    const { router, calls } = harness();
    const result = await router.call("shadow_cos", spelling, {});
    assert.equal(calls.length, 0);
    assert.equal(result.code, "emptyAction");
    assert.match(String(result.message), /briefing, negotiation_prompt/);
  }
});

test("a payload that is not a JSON object never goes on the wire", async () => {
  for (const payload of ["report.pdf", 7, ["a", "b"], true]) {
    const { router, calls } = harness();
    const result = await router.call("zerotrace_studio", "strip", payload);
    assert.equal(calls.length, 0);
    assert.equal(result.code, "invalidPayload");
    assert.match(String(result.message), /JSON object/);
  }
  const absent = harness();
  const empty = await absent.router.call("edge_compute_mesh", "summary", undefined);
  assert.equal(empty.ok, true);
  assert.deepEqual(invokeBody(absent.calls[0])["payload"], {}, "no payload means the empty object");
});

/** The five spellings the node routes into `lockdown`, pinned here as ground truth. */
const LOCKDOWN_SPELLINGS = ["lockdown", "lock", "lock_all", "sentinel", "\u{1F512}"];

test("the routing table denies exactly those spellings, and nothing else", () => {
  const derived = Object.entries(ROUTES.phantom_sentinel.aliases)
    .filter(([, canonical]) => ROUTES.phantom_sentinel.denied.includes(canonical))
    .map(([spelling]) => spelling)
    .sort();
  assert.deepEqual(derived, [...LOCKDOWN_SPELLINGS].sort());
  assert.deepEqual([...ROUTES.phantom_sentinel.denied], ["lockdown"]);
  assert.deepEqual([...ROUTES.phantom_sentinel.canonical], ["status"]);
  // `lock` for chrono_ark seals a vault. Denial is per service, keyed on the canonical name.
  assert.equal(ROUTES.chrono_ark.aliases["lock"], "seal");
  assert.deepEqual([...ROUTES.chrono_ark.denied], []);
});

test("every lockdown spelling is refused without a network call, even with no handoff at all", async () => {
  for (const spelling of LOCKDOWN_SPELLINGS) {
    const { router, calls, logs, events } = harness({ handoff: "", env: {} });
    const result = await router.call("phantom_sentinel", spelling, { confirm: "yes" });
    assert.equal(calls.length, 0, `${spelling} must not open a socket`);
    assert.equal(result.ok, false);
    assert.equal(result.code, "lockdownDenied");
    assert.match(String(result.message), /CONTRACT\.md section 7/);
    assert.ok(logs.length > 0, "a refusal must be visible to the operator");
    assert.ok(
      events().some((entry) => entry.event === "refused_lockdownDenied"),
      `refusal of ${spelling} must be logged`
    );
  }
});

test("sentinel status is still offered, because it is report-only", async () => {
  const { router, calls } = harness();
  const result = await router.call("phantom_sentinel", "status", {});
  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
  assert.deepEqual(invokeBody(calls[0]), { kind: "phantom_sentinel", action: "status", payload: {} });
  // The service alias `lockdown` is a name for the service, not a request to lock.
  const byAlias = harness();
  assert.equal((await byAlias.router.call("lockdown", "probe", {})).ok, true);
  assert.deepEqual(invokeBody(byAlias.calls[0]), { kind: "phantom_sentinel", action: "status", payload: {} });
});

test("allowLockdown without a secret is secretRequired, and still sends nothing", async () => {
  const { router, calls, events } = harness({ allowLockdown: true, secret: "short" });
  const result = await router.call("phantom_sentinel", "lock_all", {});
  assert.equal(calls.length, 0);
  assert.equal(result.code, "secretRequired");
  assert.match(String(result.message), /16 characters/);
  assert.ok(events().some((entry) => entry.event === "refused_secretRequired"));

  const envOnly = harness({ allowLockdown: true });
  assert.equal((await envOnly.router.call("phantom_sentinel", "lockdown", {})).code, "secretRequired");
  assert.equal(envOnly.calls.length, 0);
});

test("the opt-in path needs the flag and a 16-character secret, then sends once", async () => {
  const { router, calls, events } = harness({ allowLockdown: true, secret: SECRET });
  const result = await router.call("phantom_sentinel", "lockdown", {});
  assert.equal(result.ok, true);
  assert.equal(calls.length, 1, "one send, no resend of a physical action");
  assert.equal(invokeBody(calls[0])["action"], "lockdown");
  assert.ok(events().some((entry) => entry.event === "lockdownOptInGranted"));
});

test("PPX_ALLOW_LOCKDOWN in the environment is what the service template would set", async () => {
  const { router, calls } = harness({ allowLockdown: undefined, env: { PPX_ALLOW_LOCKDOWN: "1" } });
  assert.equal((await router.call("phantom_sentinel", "lockdown", {})).code, "secretRequired");
  assert.equal(calls.length, 0);
  const off = harness({ env: { PPX_ALLOW_LOCKDOWN: "off" } });
  assert.equal((await off.router.call("phantom_sentinel", "lockdown", {})).code, "lockdownDenied");
});

test("a 401 is tokenRejected with no retry", async () => {
  const { router, calls } = harness({ handler: () => textResponse("401 Missing or wrong console token.", 401) });
  const result = await router.call("shadow_cos", "briefing", {});
  assert.equal(result.ok, false);
  assert.equal(result.code, "tokenRejected");
  assert.equal(calls.length, 1, "a restart minted a new token; resending the old one is a loop");
});

test("a refused connection is retried exactly once, and a still-refused node gives up after two", async () => {
  const recovered = harness({
    handler: (_call, index) => (index === 0 ? Promise.reject(refusedConnection()) : jsonResponse(resultFixture()))
  });
  const first = await recovered.router.call("shadow_cos", "briefing", {});
  assert.equal(first.ok, true);
  assert.equal(recovered.calls.length, 2);

  const alwaysDown = harness({ handler: () => Promise.reject(refusedConnection()) });
  const second = await alwaysDown.router.call("shadow_cos", "briefing", {});
  assert.equal(second.ok, false);
  assert.equal(second.code, "nodeUnreachable");
  assert.equal(alwaysDown.calls.length, 2, "at most one retry, never a loop");
});

test("a 503 is never resent, because the node may already have sealed or granted", async () => {
  const { router, calls } = harness({ handler: () => textResponse("server is busy", 503) });
  const result = await router.call("chrono_ark", "seal", { path: "~/vault" });
  assert.equal(result.code, "nodeBusy");
  assert.equal(calls.length, 1);
});

test("an over-budget CJK payload is refused by the grapheme budget, with no call", async () => {
  const { router, calls } = harness();
  const result = await router.call("shadow_cos", "briefing", { note: "记录一份简报".repeat(200) });
  assert.equal(calls.length, 0);
  assert.equal(result.code, "payloadBudget");
  assert.match(String(result.message), /graphemes/);
});

test("the budget counts grapheme clusters, the way Swift counts Characters", async () => {
  // One family emoji is one grapheme cluster and eight UTF-16 units: 100 of them fit the budget only
  // if the bridge counts clusters, which is what `NodeWire.parseCommand` charges against 1 024.
  const family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}";
  const { router, calls } = harness();
  const result = await router.call("shadow_cos", "briefing", { k: family.repeat(100) });
  assert.equal(result.ok, true, String(result.message));
  assert.equal(calls.length, 1);
  const text = JSON.stringify({ k: family.repeat(100) });
  assert.ok(graphemeCount(text) < text.length, "the cluster count, not the UTF-16 length");

  // shadow_cos::briefing charges 10 + 8 + 2, so the payload may carry 1 004 clusters.
  const envelope = '{"k":""}';
  const fits = harness();
  assert.equal(
    (await fits.router.call("shadow_cos", "briefing", { k: "\u{1F4D3}".repeat(1_004 - envelope.length) })).ok,
    true,
    "exactly at the budget is inside it"
  );
  const over = harness();
  assert.equal(
    (await over.router.call("shadow_cos", "briefing", { k: "\u{1F4D3}".repeat(1_004 - envelope.length + 1) }))
      .code,
    "payloadBudget"
  );
  assert.equal(over.calls.length, 0);
});

test("a non-loopback handoff is refused before anything is sent", async () => {
  for (const handoff of ["http://10.0.0.5:18920/?t=x", "http://example.com:18920/?t=x"]) {
    const { router, calls } = harness({ handoff });
    const result = await router.call("shadow_cos", "briefing", {});
    assert.equal(result.code, "nonLoopbackTarget");
    assert.equal(calls.length, 0, "a bearer secret must never leave loopback");
  }
  const https = harness({ handoff: `https://127.0.0.1:18920/?t=${TOKEN}` });
  assert.equal((await https.router.call("shadow_cos", "briefing", {})).code, "nonLoopbackTarget");
  assert.equal(https.calls.length, 0);
});

test("no handoff at all is a typed result, not an exception at the host", async () => {
  const { router, calls } = harness({ handoff: "", env: {} });
  const result = await router.call("health_sentinel", "read", {});
  assert.equal(result.ok, false);
  assert.equal(result.code, "tokenRejected");
  assert.match(String(result.message), /PPX_CONSOLE_TOKEN/);
  assert.equal(calls.length, 0);
});

test("only one command is in flight per node, and the second caller is told", async () => {
  let release!: (response: Response) => void;
  const gate = new Promise<Response>((resolve) => {
    release = resolve;
  });
  // One Response cannot be read twice, so the gate holds the first call and every later call gets
  // its own answer.
  let gated = true;
  const { router, calls } = harness({
    handler: () => (gated ? gate : jsonResponse(resultFixture()))
  });
  const first = router.call("solo_autopilot", "run", {});
  const second = await router.call("solo_autopilot", "script", {});
  assert.equal(second.code, "inFlightLimit");
  assert.ok(second.message && /in flight/.test(second.message));
  release(jsonResponse(resultFixture()));
  assert.equal((await first).ok, true);
  assert.equal(calls.length, 1, "the refused caller never reached the socket");

  gated = false;
  const after = await router.call("solo_autopilot", "script", {});
  assert.equal(after.ok, true, "the slot is released, so the node cannot be wedged by one refusal");
});

test("the logger never carries the token, even when the node quotes it", async () => {
  const { router, logs } = harness({
    handler: () => textResponse(`401 Missing or wrong console token. You sent ${TOKEN}.`, 401)
  });
  const result = await router.call("shadow_cos", "briefing", {});
  assert.equal(result.code, "tokenRejected");
  assert.ok(!logs.some((line) => line.includes(TOKEN)), "no log line may contain the bearer secret");
  assert.ok(!String(result.message).includes(TOKEN), "nor may the message handed back to the host");
  assert.ok(logs.some((line) => line.includes("commandFailed_tokenRejected")), "the operator can see which call died");
  assert.ok(logs.some((line) => line.includes("30 chars, ends 89ab")), "the fingerprint identifies the token without carrying it");
});

test("the logger scrubs the token, a ?t= query and the header form", () => {
  const lines: string[] = [];
  const logger = new BridgeLogger({ sink: (line) => lines.push(line) });
  logger.protect(TOKEN);
  logger.info("handoff", { url: `http://127.0.0.1:18920/?t=${TOKEN}`, header: TOKEN });
  assert.equal(lines.length, 1);
  assert.ok(!lines[0]?.includes(TOKEN));
  // Unregistered secrets still cannot ride a `?t=` or a header field out of a log line.
  const naive: string[] = [];
  const plain = new BridgeLogger({ sink: (line) => naive.push(line) });
  plain.error("echo", { body: `the url was http://127.0.0.1:18920/?t=${TOKEN} indeed` });
  assert.ok(!naive[0]?.includes(TOKEN), naive[0]);
  const raw = new BridgeLogger({ sink: (line) => naive.push(line) });
  assert.equal(raw.redact(`{"X-PPX-Token":"${TOKEN}"}`), `{"X-PPX-Token":"${REDACTED}"}`);
  assert.equal(raw.redact(`token=${TOKEN}`), `token=${REDACTED}`);
});

test("one event is one line, and long values are cut rather than wrapped", () => {
  const lines: string[] = [];
  const logger = new BridgeLogger({ sink: (line) => lines.push(line), maxValueChars: 40 });
  logger.warn("long", { body: "x".repeat(5_000), nested: { deep: "y".repeat(5_000) } });
  assert.equal(lines.length, 1);
  assert.ok(lines[0]?.endsWith("\n"));
  assert.equal(lines[0]?.split("\n").length, 2, "content plus one trailing newline, never a wrapped second line");
  const entry = JSON.parse(lines[0] ?? "{}") as { event: string; fields: Record<string, unknown> };
  assert.equal(entry.event, "long");
  assert.ok(String(entry.fields["body"]).length < 120);
  assert.match(String(entry.fields["body"]), /\[truncated\]/);
});

test("runLine takes a canonical wire line and keeps the same rules", async () => {
  const { router, calls } = harness();
  const sent = await router.runLine(`${COMMAND_PREFIX}warroom::register::{"file":"a.pdf"}`);
  assert.equal(sent.ok, true);
  assert.deepEqual(invokeBody(calls[0]), { kind: "zero_trust_warroom", action: "assign", payload: { file: "a.pdf" } });

  const denied = await router.runLine(`${COMMAND_PREFIX}phantom_sentinel::lock_all::{"x":1}`);
  assert.equal(denied.code, "lockdownDenied");
  assert.equal(calls.length, 1, "the refusal did not open a second call");

  const malformed = await router.runLine("shadow_cos::briefing::{}");
  assert.equal(malformed.code, "malformedCommand");
  const emptyPayload = await router.runLine(`${COMMAND_PREFIX}shadow_cos::briefing::`);
  assert.equal(emptyPayload.code, "malformedCommand");
  const notAnObject = await router.runLine(`${COMMAND_PREFIX}shadow_cos::briefing::["a"]`);
  assert.equal(notAnObject.code, "malformedCommand");
  assert.match(String(notAnObject.message), /JSON object/);
});

test("register() gives the host ten tools and no handler ever throws", async () => {
  const registered: { name: string; handler: (input: unknown) => Promise<unknown> }[] = [];
  const lines: string[] = [];
  // A host that would rather fail loudly than reach a real port: nothing here may open a socket.
  const refusedFetch = (async () => {
    throw refusedConnection();
  }) as unknown as typeof fetch;
  const registration = plugin.register({
    registerTool: (tool, handler) => {
      registered.push({ name: tool.name, handler });
    },
    log: (line) => lines.push(line),
    config: { handoff: HANDOFF, env: {}, fetchImpl: refusedFetch }
  });
  assert.equal(registered.length, 10);
  assert.deepEqual(
    registered.map((entry) => entry.name),
    SERVICE_IDS.map((id) => `popopx_${id}`)
  );
  assert.deepEqual(registration.deniedActions, ["phantom_sentinel:lockdown"]);
  assert.equal(registration.tools.length, 10);
  assert.ok(lines.includes("registered popopx_shadow_cos -> shadow_cos"));

  const sentinel = registered.find((entry) => entry.name === "popopx_phantom_sentinel");
  assert.ok(sentinel);
  const refused = await sentinel.handler({ action: "lockdown", payload: {} });
  assert.equal((refused as { code: string }).code, "lockdownDenied");
  const junk = await sentinel.handler("not-an-object");
  assert.equal(typeof (junk as { ok: boolean }).ok, "boolean");
  const nothing = await sentinel.handler(undefined);
  assert.equal((nothing as { code: string }).code, "invalidPayload");
  const bareActionString = await sentinel.handler("status");
  assert.equal((bareActionString as { code: string }).code, "nodeUnreachable", "the fake fetch is the point");
});

test("the generated tool definitions are the manifest's, in the same order", () => {
  const { manifest } = readManifest();
  const definitions = buildToolDefinitions();
  assert.equal(definitions.length, manifest.tools.length);
  for (const [index, definition] of definitions.entries()) {
    const declared = manifest.tools[index];
    assert.equal(definition.name, declared?.name);
    assert.deepEqual(definition.inputSchema.properties, declared?.inputSchema.properties);
    assert.ok(definition.description.length > 20, `${definition.name} needs a description the model can use`);
    if (declared?.service === "phantom_sentinel") {
      assert.match(definition.description, /refused by this plugin/);
      assert.match(definition.description, /section 7/);
    }
  }
});

interface ManifestTool {
  readonly name: string;
  readonly service: ServiceId;
  readonly canonicalActions: readonly string[];
  readonly refusedActions: readonly string[];
  readonly inputSchema: { readonly properties: { readonly action: { readonly enum: readonly string[] } } };
}

interface Manifest {
  readonly id: string;
  readonly version: string;
  readonly entry: string;
  readonly tools: readonly ManifestTool[];
  readonly deniedTools: readonly {
    readonly service: string;
    readonly action: string;
    readonly spellings: readonly string[];
    readonly why: string;
    readonly refusedBeforeNetworkCall: boolean;
  }[];
  readonly credentials: readonly {
    readonly name: string;
    readonly env: string;
    readonly secret?: boolean;
    readonly required?: boolean;
    readonly persisted?: boolean;
    readonly value?: unknown;
  }[];
  readonly policy: {
    readonly grammar: string;
    readonly payloadBudgetGraphemes: number;
    readonly emptyActionAllowed: boolean;
    readonly payloadMustBeJsonObject: boolean;
  };
  readonly serialisation: { readonly maxInFlightCommandsPerNode: number; readonly retries: number };
  readonly console: { readonly origin: string; readonly port: number };
}

function readManifest(): { text: string; manifest: Manifest } {
  const text = readFileSync(join(ROOT, "openclaw.plugin.json"), "utf8");
  return { text, manifest: JSON.parse(text) as Manifest };
}

test("openclaw.plugin.json describes the routing table the kernel exports", () => {
  const { text, manifest } = readManifest();
  assert.equal(manifest.entry, "dist/src/index.js");
  assert.ok(existsSync(join(ROOT, manifest.entry)), "the manifest entry must exist after a build");
  assert.equal(manifest.version, PLUGIN_VERSION);
  assert.equal(manifest.console.origin, "http://127.0.0.1:18920");
  assert.equal(manifest.console.port, 18_920);
  assert.equal(manifest.policy.grammar, `${COMMAND_PREFIX}{serviceId}::{action}::{payload}`);
  assert.equal(manifest.policy.payloadBudgetGraphemes, 1_024);
  assert.equal(manifest.policy.emptyActionAllowed, false);
  assert.equal(manifest.policy.payloadMustBeJsonObject, true);
  assert.equal(manifest.serialisation.maxInFlightCommandsPerNode, 1);
  assert.equal(manifest.serialisation.retries, 1);
  assert.ok(!text.includes(TOKEN), "the manifest is a committed file, so it can never hold a token");

  assert.equal(manifest.tools.length, SERVICE_IDS.length);
  assert.deepEqual(
    manifest.tools.map((tool) => tool.service).sort(),
    [...SERVICE_IDS].sort()
  );
  for (const tool of manifest.tools) {
    const table = ROUTES[tool.service];
    assert.equal(tool.name, `popopx_${tool.service}`);
    assert.deepEqual(tool.canonicalActions, [...table.canonical]);
    assert.deepEqual(tool.refusedActions, table.denied.map((action) => `${tool.service}:${action}`));
    const offered = tool.inputSchema.properties.action.enum;
    assert.ok(offered.length > 0, `${tool.service} offers nothing`);
    for (const value of offered) {
      assert.notEqual(value, "", "the node's empty-action default is refused by the bridge");
      const canonical = table.aliases[value];
      assert.ok(canonical !== undefined, `${tool.service}: the manifest offers ${value}, the routing table does not`);
      assert.ok(!table.denied.includes(canonical), `${tool.service}: the manifest offers the denied action ${value}`);
    }
    for (const canonical of table.canonical) {
      if (table.denied.includes(canonical)) continue;
      assert.ok(offered.includes(canonical), `${tool.service}: canonical ${canonical} is missing from the manifest`);
    }
    assert.deepEqual(offered, [...tableAllowedActions(tool.service)], `${tool.service} drifted from tableAllowedActions`);
  }

  const sentinel = manifest.tools.find((tool) => tool.service === "phantom_sentinel");
  assert.ok(sentinel);
  assert.deepEqual(sentinel.inputSchema.properties.action.enum, ["status", "probe"]);

  const refusal = manifest.deniedTools.find((entry) => entry.service === "phantom_sentinel" && entry.action === "lockdown");
  assert.ok(refusal, "the manifest must name the lockdown refusal, not omit it");
  assert.equal(refusal.refusedBeforeNetworkCall, true);
  assert.deepEqual([...refusal.spellings].sort(), [...LOCKDOWN_SPELLINGS].sort());
  assert.match(refusal.why, /no confirmation/);
  for (const spelling of LOCKDOWN_SPELLINGS) {
    assert.ok(refusal.spellings.includes(spelling), `the refusal must name ${spelling}`);
    assert.ok(
      !sentinel.inputSchema.properties.action.enum.includes(spelling),
      `the offered enum for phantom_sentinel must not contain ${spelling}`
    );
  }
  assert.ok(text.includes("\u{1F512}"), "the manifest names the emoji spelling it refuses");
});

test("the manifest hands the token through the environment only", () => {
  const { text, manifest } = readManifest();
  const consoleToken = manifest.credentials.find((entry) => entry.env === "PPX_CONSOLE_TOKEN");
  assert.ok(consoleToken, "PPX_CONSOLE_TOKEN must be declared as an env credential");
  assert.equal(consoleToken.secret, true);
  assert.equal(consoleToken.required, true);
  assert.equal(consoleToken.persisted, false);
  assert.ok(!("literal" in consoleToken));
  assert.equal(consoleToken.value ?? null, null, "a credential field carries no value, only the variable name");
  const secret = manifest.credentials.find((entry) => entry.env === "PPX_BRIDGE_SECRET");
  assert.ok(secret, "the lockdown secret is env-based too");
  assert.equal(secret.value ?? null, null);
  assert.match(text, /X-PPX-Token/, "the manifest says how the token is carried");
  assert.ok(!/"token":\s*"/.test(text), "no field may look like an inline token value");
});

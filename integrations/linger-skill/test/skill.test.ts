/**
 * The Linger skill suite, run against a fake `fetch` so no node is involved.
 *
 * Two things here carry the weight. First, the requests the fake records are the only evidence that a
 * host spelling became the canonical one the node expects: `daily` must arrive as `briefing`, and
 * `warroom` must arrive as `zero_trust_warroom`. Second, several tests assert on the *absence* of a
 * call, which is the whole point of CONTRACT §7 — a lockdown refusal that opened a socket would not be
 * a refusal.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  MAX_SIGNAL_PAYLOAD_CHARACTERS,
  ROUTES,
  SERVICE_IDS,
  canonicalAction,
  graphemeCount,
  resolveServiceId,
  type CommandResult,
  type ServiceId
} from "@popopx/node-bridge";

import {
  SKILL_INPUT_FIELDS,
  SKILL_NAME,
  cachedBridgeCount,
  clearBridgeCache,
  renderResult,
  run,
  services,
  type LingerSkillFailure,
  type LingerSkillSuccess
} from "../src/index.js";
import { CONFIG_KEYS, buildCommand, loadConfigFile, resolveSettings, type ConfigFile } from "../src/handlers.js";
import { SkillLogger, secretCandidates } from "../src/log.js";

const HOST = "127.0.0.1";
const PORT = 18_920;
const INVOKE_URL = `http://${HOST}:${PORT}/api/engine/invoke`;
const SECRET = "plugin-shared-secret-of-sixteen";

let tokenSeq = 0;

/** A different token per test: the per-node client cache keys on it, so tests cannot see each other. */
function handoff(): { readonly url: string; readonly token: string } {
  tokenSeq += 1;
  const token = `Tk${String(tokenSeq).padStart(3, "0")}AbCdEf0123456789_-xyz`;
  return { url: `http://${HOST}:${PORT}/?t=${token}`, token };
}

interface Call {
  readonly url: string;
  readonly method: string;
  readonly headers: Record<string, string>;
  readonly body?: string;
}

interface Transport {
  readonly fetchImpl: typeof fetch;
  readonly calls: Call[];
}

function transport(handler: (call: Call, index: number) => Response | Promise<Response>): Transport {
  const calls: Call[] = [];
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
  return { fetchImpl, calls };
}

/** A transport that must never be touched: reaching it fails the test, it does not answer. */
function forbiddenTransport(): Transport {
  return transport(() => {
    throw new Error("the skill opened a socket where it must not");
  });
}

const jsonResponse = (payload: unknown, status = 200): Response =>
  new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });

const textResponse = (text: string, status = 200): Response =>
  new Response(text, { status, headers: { "content-type": "text/plain" } });

function refusedConnection(): TypeError {
  const cause = Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:18920"), {
    code: "ECONNREFUSED",
    syscall: "connect"
  });
  return Object.assign(new TypeError("fetch failed"), { cause });
}

function timeoutError(): Error {
  return Object.assign(new Error("The operation was aborted due to timeout"), { name: "TimeoutError" });
}

function resultFixture(over: Partial<CommandResult> = {}): CommandResult {
  return {
    id: "r-1",
    commandID: "c-1",
    engine: "shadow_cos",
    ok: true,
    deterministic: false,
    headline: "briefing ready",
    body: "line one",
    artifacts: [],
    durationMs: 12,
    at: "2026-11-21T09:10:11Z",
    metrics: { unknownAction: false },
    ...over
  };
}

function successBody(over: Partial<CommandResult> = {}): Response {
  return jsonResponse(resultFixture(over));
}

function onlyCall(t: Transport): Call {
  assert.equal(t.calls.length, 1, "exactly one request should have been made");
  const call = t.calls[0];
  assert.ok(call !== undefined);
  return call;
}

function invokeBody(call: Call): { kind: string; action: string; payload: Record<string, unknown> } {
  assert.ok(call.body !== undefined, "the invoke request must carry a body");
  return JSON.parse(call.body) as { kind: string; action: string; payload: Record<string, unknown> };
}

function asSuccess(out: Awaited<ReturnType<typeof run>>): LingerSkillSuccess {
  assert.equal(out.ok, true, `expected success, got ${JSON.stringify(out)}`);
  return out as LingerSkillSuccess;
}

function asFailure(out: Awaited<ReturnType<typeof run>>): LingerSkillFailure {
  assert.equal(out.ok, false, `expected failure, got ${JSON.stringify(out)}`);
  return out as LingerSkillFailure;
}

interface LogLine {
  readonly ts: string;
  readonly level: string;
  readonly event: string;
  readonly skill: string;
  readonly [key: string]: unknown;
}

function logCollector(): { readonly lines: string[]; readonly sink: (line: string) => void; readonly records: () => LogLine[] } {
  const lines: string[] = [];
  return {
    lines,
    sink: (line: string): void => {
      lines.push(line);
    },
    records: (): LogLine[] => lines.map((line) => JSON.parse(line) as LogLine)
  };
}

const packageRoot = fileURLToPath(new URL("../../", import.meta.url));

function readPackageFile(relative: string): string {
  return readFileSync(join(packageRoot, relative), "utf8");
}

// MARK: - the canonical round trip

test("a host alias is canonicalised before the node sees it", async () => {
  const { url, token } = handoff();
  const t = transport(() => successBody({ body: "x".repeat(1_900) }));

  const out = asSuccess(
    await run({ service: "shadow_cos", action: "daily", payload: { tone: "terse" }, handoff: url, fetch: t.fetchImpl })
  );

  const call = onlyCall(t);
  assert.equal(call.url, INVOKE_URL);
  assert.equal(call.method, "POST");
  assert.equal(call.headers["x-ppx-token"], token, "the token travels in the header, not in the path");
  assert.equal(call.headers["content-type"], "application/json");
  assert.deepEqual(invokeBody(call), { kind: "shadow_cos", action: "briefing", payload: { tone: "terse" } });
  assert.equal(call.url.includes(token), false, "the token must not be in the request path");

  assert.equal(out.service, "shadow_cos");
  assert.equal(out.action, "briefing");
  assert.equal(out.line, '::popopx_sys::NODE_CMD::shadow_cos::briefing::{"tone":"terse"}');
  assert.equal(out.headline, "briefing ready");
  assert.equal(out.body.length, 1_900, "the node already truncates at 1 800; the adapter must not re-cut");
  assert.equal(out.durationMs, 12);
  assert.equal(out.nodeOk, true);
  assert.equal(out.at, "2026-11-21T09:10:11Z");
  assert.equal(out.resultId, "r-1");
  assert.equal(out.commandId, "c-1");
  assert.equal(out.origin, `http://${HOST}:${PORT}`);
  assert.match(out.tokenFingerprint, /^\d+ chars, ends /);
  assert.equal(out.message, out.headline);
});

test("the node's own refusal is carried without being called a transport failure", async () => {
  const { url } = handoff();
  const t = transport(() =>
    successBody({ ok: false, artifacts: ["/tmp/a.mp4", "/tmp/b.json"], headline: "unknown action", durationMs: 3 })
  );

  const out = asSuccess(await run({ service: "morning_tv", action: "digest", handoff: url, fetch: t.fetchImpl }));
  assert.equal(out.nodeOk, false, "the node answered and refused; the call itself still succeeded");
  assert.deepEqual(out.artifacts, ["/tmp/a.mp4", "/tmp/b.json"]);
  assert.equal(out.durationMs, 3);
  assert.match(out.text, /refused · morning_tv · digest/);
  assert.match(out.text, /unknown action/);
  assert.match(out.text, /artifact \/tmp\/a\.mp4/);
  assert.match(out.text, /3 ms/);
});

test("an alias service id reaches its canonical engine", async () => {
  const { url } = handoff();
  const t = transport(() => successBody({ engine: "zero_trust_warroom" }));

  const out = asSuccess(await run({ service: "warroom", action: "register", payload: {}, handoff: url, fetch: t.fetchImpl }));
  const body = invokeBody(onlyCall(t));
  assert.equal(body.kind, "zero_trust_warroom");
  assert.equal(body.action, "assign");
  assert.deepEqual(body.payload, {});
  assert.equal(out.service, "zero_trust_warroom");
  assert.equal(out.action, "assign");
});

test("an empty payload defaults to the JSON object the invoke route needs", async () => {
  const { url } = handoff();
  const t = transport(() => successBody());
  asSuccess(await run({ service: "chrono_ark", action: "heartbeat", handoff: url, fetch: t.fetchImpl }));
  assert.deepEqual(invokeBody(onlyCall(t)).payload, {});
});

test("a payload that already is JSON text is not double-encoded", async () => {
  const { url } = handoff();
  const t = transport(() => successBody());
  asSuccess(
    await run({
      service: "health_sentinel",
      action: "read",
      payload: '{"src":"report.pdf","page":2}',
      handoff: url,
      fetch: t.fetchImpl
    })
  );
  assert.deepEqual(invokeBody(onlyCall(t)).payload, { src: "report.pdf", page: 2 });
});

test("the handoff may be empty when PPX_CONSOLE_TOKEN carries the token", async () => {
  const { token } = handoff();
  const t = transport(() => successBody());
  asSuccess(await run({ service: "solo_autopilot", action: "generate", env: { PPX_CONSOLE_TOKEN: token }, fetch: t.fetchImpl }));
  const call = onlyCall(t);
  assert.equal(call.url, INVOKE_URL);
  assert.equal(call.headers["x-ppx-token"], token);
  assert.equal(invokeBody(call).action, "run");
});

// MARK: - the lockdown gate

const LOCKDOWN_SPELLINGS = ["lockdown", "lock", "lock_all", "sentinel", "\u{1F512}"] as const;

test("every lockdown spelling is refused with zero network calls", async () => {
  for (const spelling of LOCKDOWN_SPELLINGS) {
    const { url } = handoff();
    const t = forbiddenTransport();
    const log = logCollector();

    const out = asFailure(
      await run({
        service: "phantom_sentinel",
        action: spelling,
        payload: { confirm: "yes" },
        handoff: url,
        fetch: t.fetchImpl,
        log: log.sink
      })
    );

    assert.equal(out.code, "lockdownDenied", `action ${spelling} must be refused before the socket`);
    assert.equal(t.calls.length, 0, `action ${spelling} must never open a socket`);
    assert.match(out.line ?? "", /^::popopx_sys::NODE_CMD::phantom_sentinel::lockdown::/);
    assert.match(out.detail ?? "", /CONTRACT\.md section 7/);
    assert.match(out.detail ?? "", /blocked canonical actions for phantom_sentinel: lockdown/);

    const refusals = log.records().filter((record) => record.event === "refusal");
    assert.equal(refusals.length, 1, `action ${spelling} must be logged as one refusal`);
    assert.equal(refusals[0]?.["code"], "lockdownDenied");
    assert.equal(refusals[0]?.["allowLockdown"], false);
    assert.equal(typeof refusals[0]?.["line"], "string");
    assert.equal(refusals[0]?.["outcomeUnknown"], false, "a refusal never means the node acted");
  }
});

test("the refusal is the same for the canonical id and for both service aliases", async () => {
  for (const service of ["phantom_sentinel", "sentinel", "lockdown"]) {
    const t = forbiddenTransport();
    const out = asFailure(await run({ service, action: "lock_all", handoff: handoff().url, fetch: t.fetchImpl }));
    assert.equal(out.code, "lockdownDenied");
    assert.equal(out.service, "phantom_sentinel", "the id is canonicalised even when the answer is no");
    assert.equal(t.calls.length, 0);
  }
});

test("a lockdown refusal outranks a missing handoff", async () => {
  const t = forbiddenTransport();
  const out = asFailure(await run({ service: "phantom_sentinel", action: "lockdown", fetch: t.fetchImpl }));
  assert.equal(out.code, "lockdownDenied", "policy is decided before the console target is even resolved");
  assert.equal(t.calls.length, 0);
});

test("allowLockdown without a secret is secretRequired, still with zero calls", async () => {
  const t = forbiddenTransport();
  const out = asFailure(
    await run({
      service: "phantom_sentinel",
      action: "lockdown",
      handoff: handoff().url,
      allowLockdown: true,
      fetch: t.fetchImpl
    })
  );
  assert.equal(out.code, "secretRequired");
  assert.equal(t.calls.length, 0);
});

test("allowLockdown with a short secret is secretRequired, still with zero calls", async () => {
  const shortSecret = "short-secret-15";
  assert.equal(shortSecret.length, 15, "this fixture must stay under the kernel's 16-character floor");
  const t = forbiddenTransport();
  const log = logCollector();
  const out = asFailure(
    await run({
      service: "phantom_sentinel",
      action: "lock_all",
      handoff: handoff().url,
      allowLockdown: true,
      secret: shortSecret,
      fetch: t.fetchImpl,
      log: log.sink
    })
  );
  assert.equal(out.code, "secretRequired");
  assert.match(out.message, /at least 16 characters/);
  assert.equal(t.calls.length, 0);
  assert.equal(log.records().filter((record) => record.event === "refusal").length, 1);
  assert.equal(log.lines.join("\n").includes(shortSecret), false, "a rejected secret stays out of the log");
});

test("allowLockdown plus a 16-character secret is the only path that sends a lockdown", async () => {
  const { url } = handoff();
  const t = transport(() => successBody({ deterministic: true, headline: "locked" }));
  const out = asSuccess(
    await run({
      service: "phantom_sentinel",
      action: "lockdown",
      handoff: url,
      allowLockdown: true,
      secret: SECRET,
      fetch: t.fetchImpl
    })
  );
  assert.equal(invokeBody(onlyCall(t)).action, "lockdown");
  assert.equal(out.deterministic, true);
});

test("the secret may come from PPX_BRIDGE_SECRET instead of the argument", async () => {
  const { url } = handoff();
  const t = transport(() => successBody());
  asSuccess(
    await run({
      service: "phantom_sentinel",
      action: "\u{1F512}",
      handoff: url,
      env: { PPX_BRIDGE_SECRET: SECRET },
      allowLockdown: true,
      fetch: t.fetchImpl
    })
  );
  assert.equal(invokeBody(onlyCall(t)).action, "lockdown");
});

test("a broken config file cannot loosen the lockdown gate", async () => {
  const dir = mkdtempSync(join(tmpdir(), "popopx-linger-"));
  try {
    const path = join(dir, "broken.json");
    writeFileSync(path, "{ not json", "utf8");
    const t = forbiddenTransport();
    const out = asFailure(
      await run({
        service: "phantom_sentinel",
        action: "lockdown",
        handoff: handoff().url,
        env: { PPX_SKILL_CONFIG: path },
        fetch: t.fetchImpl
      })
    );
    assert.equal(out.code, "lockdownDenied", "policy is judged with the safe defaults, not with the unread file");
    assert.equal(t.calls.length, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("phantom_sentinel status stays available", async () => {
  const { url } = handoff();
  const t = transport(() => successBody({ engine: "phantom_sentinel" }));
  asSuccess(await run({ service: "phantom_sentinel", action: "probe", handoff: url, fetch: t.fetchImpl }));
  const body = invokeBody(onlyCall(t));
  assert.equal(body.kind, "phantom_sentinel");
  assert.equal(body.action, "status", "probe is the report-only alias and canonicalises to status");
});

test("chrono_ark lock is a vault seal, not a screen lock", async () => {
  const { url } = handoff();
  const t = transport(() => successBody());
  asSuccess(await run({ service: "chrono_ark", action: "lock", handoff: url, fetch: t.fetchImpl }));
  const body = invokeBody(onlyCall(t));
  assert.equal(body.kind, "chrono_ark");
  assert.equal(body.action, "seal");
});

// MARK: - grammar and configuration failures

test("an unknown action is a grammar failure with zero calls", async () => {
  const t = forbiddenTransport();
  const log = logCollector();
  const out = asFailure(
    await run({ service: "shadow_cos", action: "weekly", handoff: handoff().url, fetch: t.fetchImpl, log: log.sink })
  );
  assert.equal(out.code, "malformedCommand");
  assert.match(out.message, /unknown action .weekly. for shadow_cos/);
  assert.match(out.message, /canonical actions: briefing, negotiation_prompt/);
  assert.equal(t.calls.length, 0);
  assert.ok(log.records().some((record) => record.event === "refusal" && record.code === "malformedCommand"));
});

test("an unknown service names the ids the node actually has", async () => {
  const t = forbiddenTransport();
  const out = asFailure(await run({ service: "nightly_desk", action: "run", handoff: handoff().url, fetch: t.fetchImpl }));
  assert.equal(out.code, "unknownService");
  assert.match(out.message, /Unknown service identifier/);
  assert.match(out.message, /Known ids: shadow_cos, zero_trust_warroom/);
  assert.equal(t.calls.length, 0);
});

test("an empty action is rejected even though the node would default it", async () => {
  const t = forbiddenTransport();
  const out = asFailure(await run({ service: "shadow_cos", action: "", handoff: handoff().url, fetch: t.fetchImpl }));
  assert.equal(out.code, "emptyAction");
  assert.equal(t.calls.length, 0);
});

test("a payload that is not a JSON object is rejected locally", async () => {
  for (const payload of [["one", "two"], "plain text", 42, null] as const) {
    const t = forbiddenTransport();
    const out = asFailure(
      await run({ service: "creator_paywall_hub", action: "verify", payload, handoff: handoff().url, fetch: t.fetchImpl })
    );
    assert.equal(out.code, "malformedCommand", `payload ${JSON.stringify(payload)} is not an object`);
    assert.equal(t.calls.length, 0);
  }
});

test("a non-loopback handoff is refused with zero calls", async () => {
  const cases = ["http://10.0.0.5:18920/?t=whatever", "https://127.0.0.1:18920/?t=whatever", "http://example.com:18920/?t=whatever"];
  for (const url of cases) {
    const t = forbiddenTransport();
    const out = asFailure(await run({ service: "shadow_cos", action: "briefing", handoff: url, fetch: t.fetchImpl }));
    assert.equal(out.code, "nonLoopbackTarget", `${url} must be refused`);
    assert.equal(t.calls.length, 0);
  }
});

test("a handoff with no token anywhere is tokenRejected before the socket", async () => {
  const t = forbiddenTransport();
  const out = asFailure(await run({ service: "shadow_cos", action: "briefing", handoff: "", env: {}, fetch: t.fetchImpl }));
  assert.equal(out.code, "tokenRejected");
  assert.match(out.message, /PPX_CONSOLE_TOKEN/);
  assert.equal(t.calls.length, 0);
});

test("the grapheme budget is counted the way Swift counts it", async () => {
  const budget = MAX_SIGNAL_PAYLOAD_CHARACTERS - (graphemeCount("shadow_cos") + graphemeCount("briefing") + 2);
  const head = '{"d":"';
  const tail = '"}';
  const inner = budget - graphemeCount(head) - graphemeCount(tail);
  // A regional-indicator pair is one grapheme and four UTF-16 units, which is exactly where a
  // `payload.length` check would disagree with the node.
  const flag = "\u{1F1E8}\u{1F1F3}";
  const fits = `${head}${flag.repeat(inner)}${tail}`;
  const over = `${head}${flag.repeat(inner + 1)}${tail}`;
  assert.equal(graphemeCount(fits), budget);
  assert.ok(fits.length > budget, "UTF-16 units must not decide the verdict");

  const { url } = handoff();
  const t = transport(() => successBody());
  asSuccess(await run({ service: "shadow_cos", action: "briefing", payload: fits, handoff: url, fetch: t.fetchImpl }));
  const sent = invokeBody(onlyCall(t)).payload["d"];
  assert.equal(String(sent).length, flag.length * inner);

  const refused = forbiddenTransport();
  const out = asFailure(
    await run({ service: "shadow_cos", action: "briefing", payload: over, handoff: handoff().url, fetch: refused.fetchImpl })
  );
  assert.equal(out.code, "payloadBudget");
  assert.match(out.message, /payload exceeds \d+ graphemes/);
  assert.equal(refused.calls.length, 0);
});

test("a payload containing the separator survives verbatim", async () => {
  const { url } = handoff();
  const t = transport(() => successBody());
  const out = asSuccess(
    await run({ service: "zerotrace_studio", action: "strip", payload: { path: "a::b.pdf" }, handoff: url, fetch: t.fetchImpl })
  );
  assert.deepEqual(invokeBody(onlyCall(t)).payload, { path: "a::b.pdf" });
  assert.equal(out.action, "strip");
});

test("a bad config file is a typed badConfig failure with zero calls", async () => {
  const dir = mkdtempSync(join(tmpdir(), "popopx-linger-"));
  try {
    const unknownKey = join(dir, "unknown.json");
    writeFileSync(unknownKey, JSON.stringify({ handoff: "", timeout: 5_000 }), "utf8");
    const t = forbiddenTransport();
    const out = asFailure(
      await run({
        service: "shadow_cos",
        action: "briefing",
        handoff: handoff().url,
        env: { PPX_SKILL_CONFIG: unknownKey },
        fetch: t.fetchImpl
      })
    );
    assert.equal(out.code, "badConfig");
    assert.match(out.message, /unknown config key .timeout/);
    assert.match(out.detail ?? "", /config path: .*unknown\.json/);
    assert.equal(t.calls.length, 0);

    const missing = asFailure(
      await run({
        service: "shadow_cos",
        action: "briefing",
        handoff: handoff().url,
        env: { PPX_SKILL_CONFIG: join(dir, "absent.json") },
        fetch: t.fetchImpl
      })
    );
    assert.equal(missing.code, "badConfig");
    assert.match(missing.message, /config file unreadable/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// MARK: - transport behaviour

test("a 401 is tokenRejected and is not retried", async () => {
  const { url, token } = handoff();
  const t = transport(() => textResponse("Missing or wrong console token.", 401));
  const log = logCollector();
  const out = asFailure(await run({ service: "shadow_cos", action: "briefing", handoff: url, fetch: t.fetchImpl, log: log.sink }));

  assert.equal(out.code, "tokenRejected");
  assert.equal(t.calls.length, 1, "a dead token must not become a retry loop");
  assert.match(out.detail ?? "", /node restart mints a new one/);
  assert.deepEqual(invokeBody(onlyCall(t)), { kind: "shadow_cos", action: "briefing", payload: {} });

  const joined = log.lines.join("\n");
  assert.equal(joined.includes(token), false, "no log line may carry the token");
  assert.match(joined, /tokenFingerprint/);
  assert.match(joined, /"status":401/);
});

test("a refused connection is retried exactly once", async () => {
  const { url } = handoff();
  let seen = 0;
  const t = transport(() => {
    seen += 1;
    if (seen === 1) throw refusedConnection();
    return successBody();
  });
  const out = asSuccess(await run({ service: "morning_tv", action: "broadcast", handoff: url, fetch: t.fetchImpl }));
  assert.equal(t.calls.length, 2, "the request never arrived, so one resend is allowed");
  assert.equal(out.action, "broadcast");
});

test("a connection that stays down is reported after the single retry", async () => {
  const { url } = handoff();
  const t = transport(() => {
    throw refusedConnection();
  });
  const out = asFailure(await run({ service: "morning_tv", action: "broadcast", handoff: url, fetch: t.fetchImpl }));
  assert.equal(out.code, "nodeUnreachable");
  assert.equal(t.calls.length, 2, "never more than one resend");
  assert.match(out.message, /fetch failed/);
});

test("a timeout is not retried because the outcome is unknown", async () => {
  const { url } = handoff();
  const t = transport(() => {
    throw timeoutError();
  });
  const out = asFailure(await run({ service: "creator_paywall_hub", action: "grant", handoff: url, fetch: t.fetchImpl }));
  assert.equal(out.code, "nodeUnreachable");
  assert.equal(t.calls.length, 1, "the engine may already have granted the ticket");
  assert.match(out.detail ?? "", /may still have run/);
});

test("a 5xx is not retried, because the node may already have started the work", async () => {
  const { url } = handoff();
  const t = transport(() => textResponse("server busy", 503));
  const out = asFailure(await run({ service: "edge_compute_mesh", action: "settle", handoff: url, fetch: t.fetchImpl }));
  assert.equal(out.code, "nodeBusy");
  assert.equal(t.calls.length, 1);
});

test("an untyped fault inside the host's fetch shim still returns a typed answer", async () => {
  const { url } = handoff();
  const t = transport(() => {
    throw new RangeError("the host handed in a broken transport");
  });
  const out = asFailure(await run({ service: "shadow_cos", action: "briefing", handoff: url, fetch: t.fetchImpl }));
  assert.equal(out.code, "nodeUnreachable");
  assert.match(out.message, /RangeError/);
});

test("a second command on the same node answers inFlightLimit instead of queueing", async () => {
  const { url } = handoff();
  let release = (): void => {};
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const t = transport(async () => {
    await gate;
    return successBody();
  });

  const first = run({ service: "solo_autopilot", action: "run", handoff: url, fetch: t.fetchImpl });
  const second = asFailure(await run({ service: "solo_autopilot", action: "script", handoff: url, fetch: t.fetchImpl }));
  release();
  const firstOut = asSuccess(await first);

  assert.equal(second.code, "inFlightLimit");
  assert.match(second.message, /already in flight/);
  assert.equal(t.calls.length, 1, "the refused call never reached the socket either");
  assert.equal(firstOut.action, "run");
});

test("one client per node, so the in-flight slot is shared and not simulated", async () => {
  clearBridgeCache();
  assert.equal(cachedBridgeCount(), 0);
  const a = handoff();
  const b = handoff();
  const shared = transport(() => successBody());

  await run({ service: "shadow_cos", action: "briefing", handoff: a.url, fetch: shared.fetchImpl });
  assert.equal(cachedBridgeCount(), 1);
  await run({ service: "shadow_cos", action: "briefing", handoff: a.url, fetch: shared.fetchImpl });
  assert.equal(cachedBridgeCount(), 1, "the same handoff and transport reuse one client");
  await run({ service: "shadow_cos", action: "briefing", handoff: b.url, fetch: shared.fetchImpl });
  assert.equal(cachedBridgeCount(), 2, "a different token is a different client");

  await run({ service: "shadow_cos", action: "briefing", handoff: b.url, timeoutMs: 900, fetch: shared.fetchImpl });
  assert.equal(cachedBridgeCount(), 3, "a different timeout is a different client, not a reused one");
  clearBridgeCache();
  assert.equal(cachedBridgeCount(), 0);
});

// MARK: - the logger

test("the logger scrubs registered secrets and drops forbidden keys", () => {
  const lines: string[] = [];
  const logger = new SkillLogger({ sink: (line) => lines.push(line), redact: [SECRET, "Tk001AbCdEf0123456789_-xyz"] });
  const record = logger.info("demo", {
    token: "Tk001AbCdEf0123456789_-xyz",
    secret: SECRET,
    echoed: "handoff was http://127.0.0.1:18920/?t=Tk001AbCdEf0123456789_-xyz",
    kept: "this stays",
    missing: undefined
  });

  assert.equal(lines.length, 1);
  const line = lines[0] ?? "";
  assert.equal(line.includes(SECRET), false);
  assert.equal(line.includes("Tk001AbCdEf0123456789_-xyz"), false);
  assert.equal(line.includes("\n"), false, "a record is one line");
  assert.match(line, /\[redacted\]/);
  assert.match(line, /"kept":"this stays"/);
  assert.match(line, /"redactedFields":2/);
  assert.equal(line.includes("missing"), false);
  assert.equal(record?.event, "demo");
  assert.equal(record?.skill, "linger-skill");

  const quiet = new SkillLogger({ sink: (value) => lines.push(value), quiet: true });
  assert.equal(quiet.info("silent", {}), null, "quiet drops info records");
  assert.equal(lines.length, 1);
  quiet.refusal("lockdownDenied", {});
  assert.equal(lines.length, 2, "quiet never drops a refusal: CONTRACT §7 has no opt-out");
  assert.match(lines[1] ?? "", /"level":"warn"/);
});

test("secretCandidates extracts a token from a URL and from a bare handoff", () => {
  assert.deepEqual(secretCandidates(`http://127.0.0.1:18920/?t=Tk002AbCdEf0123456789_-xyz`, ["env-token-value"]), [
    "Tk002AbCdEf0123456789_-xyz",
    "env-token-value"
  ]);
  assert.deepEqual(secretCandidates("Tk003AbCdEf0123456789_-xyz", []), ["Tk003AbCdEf0123456789_-xyz"]);
  assert.deepEqual(secretCandidates("", [undefined, ""]), []);
});

// MARK: - the shared grammar is the only grammar

test("buildCommand agrees with the kernel on the canonical spelling", () => {
  const built = buildCommand("gop_watermark", "MARK", { n: 1 });
  assert.equal(built.ok, true);
  if (!built.ok) return;
  assert.equal(built.line, '::popopx_sys::NODE_CMD::zero_trust_warroom::embed::{"n":1}');
  assert.equal(built.command.serviceId, "zero_trust_warroom");
  assert.equal(built.command.denied, false);
  assert.deepEqual(built.command.invokeBody, { kind: "zero_trust_warroom", action: "embed", payload: { n: 1 } });

  const denied = buildCommand("phantom_sentinel", "LOCK_ALL", {});
  assert.equal(denied.ok, true);
  if (!denied.ok) return;
  assert.equal(denied.command.denied, true);
  assert.equal(denied.command.action, "lockdown");

  for (const [service, action, payload, code] of [
    ["", "briefing", {}, "malformedCommand"],
    ["shadow_cos", "  ", {}, "emptyAction"],
    ["shadow_cos", "briefing", "", "malformedCommand"]
  ] as const) {
    const rejected = buildCommand(service, action, payload);
    assert.equal(rejected.ok, false, `${service} ${action} was accepted`);
    if (rejected.ok) continue;
    assert.equal(rejected.code, code);
  }
});

test("renderResult carries every field a chat host has to show", () => {
  const built = buildCommand("solo_autopilot", "video", { clip: "a.mp4" });
  assert.equal(built.ok, true);
  if (!built.ok) return;
  const text = renderResult(
    built.command,
    resultFixture({ headline: "clip ready", body: "one line", artifacts: ["/tmp/a.mp4"], durationMs: 42, ok: false })
  );
  assert.equal(text, "refused · solo_autopilot · run\nclip ready\none line\nartifact /tmp/a.mp4\n42 ms");
});

test("resolveSettings keeps the documented precedence and the safe defaults", () => {
  const direct = resolveSettings({ handoff: "  http://127.0.0.1:18920/?t=x  ", timeoutMs: 900 });
  assert.equal(direct.ok, true);
  if (!direct.ok) return;
  assert.equal(direct.settings.handoff, "http://127.0.0.1:18920/?t=x");
  assert.equal(direct.settings.timeoutMs, 900);
  assert.equal(direct.settings.allowLockdown, false, "the safe default");
  assert.equal(direct.settings.logRefusals, true, "refusals are recorded unless the operator says otherwise");
  assert.equal(direct.settings.configPath, undefined);

  const fromEnv = resolveSettings({ handoff: "", env: { PPX_BRIDGE_SECRET: SECRET } });
  assert.equal(fromEnv.ok, true);
  if (!fromEnv.ok) return;
  assert.equal(fromEnv.settings.secret, SECRET);

  assert.equal(resolveSettings({ timeoutMs: 0 }).ok, false, "a zero timeout is not a setting");
});

// MARK: - the host-facing card

interface DeclaredService {
  readonly id: string;
  readonly actions: readonly string[];
  readonly accepts: readonly string[];
  readonly also: readonly string[];
  readonly denied: readonly string[];
}

/** The mutable form the parser fills in before handing back a `DeclaredService`. */
interface DraftService {
  id: string;
  actions: string[];
  accepts: string[];
  also: string[];
  denied: string[];
}

interface SkillCard {
  readonly name: string;
  readonly description: string;
  readonly whenToUse: string;
  readonly inputs: readonly string[];
  readonly services: readonly DeclaredService[];
  readonly examples: readonly { service: string; action: string }[];
}

function list(value: string): string[] {
  const trimmed = value.trim();
  if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return [];
  return trimmed
    .slice(1, -1)
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item !== "");
}

function parseSkillCard(text: string): SkillCard {
  const lines = text.split("\n");
  assert.equal(lines[0], "---", "SKILL.md must open with frontmatter");
  const end = lines.indexOf("---", 1);
  assert.ok(end > 0, "SKILL.md frontmatter must close");
  const head = lines.slice(1, end);

  const scalar = (key: string): string => {
    const found = head.find((line) => line.startsWith(`${key}:`));
    return found === undefined ? "" : found.slice(key.length + 1).trim();
  };

  const inputs: string[] = [];
  const declared: DraftService[] = [];
  const examples: { service: string; action: string }[] = [];
  let section = "";

  for (const line of head) {
    const topLevel = /^([a-zA-Z]+):/.exec(line);
    if (topLevel !== null) {
      section = topLevel[1] ?? "";
      continue;
    }
    if (section === "inputs") {
      const key = /^\s+([a-zA-Z]+):/.exec(line);
      if (key !== null) inputs.push(key[1] ?? "");
    } else if (section === "services") {
      const id = /^\s+-\s+id:\s*(\S+)$/.exec(line);
      if (id !== null) {
        declared.push({ id: id[1] ?? "", actions: [], accepts: [], also: [], denied: [] });
        continue;
      }
      const field = /^\s+(actions|accepts|also|denied):\s*(.*)$/.exec(line);
      const current = declared[declared.length - 1];
      if (field !== null && current !== undefined) {
        const entries = list(field[2] ?? "");
        switch (field[1]) {
          case "actions":
            current.actions = entries;
            break;
          case "accepts":
            current.accepts = entries;
            break;
          case "also":
            current.also = entries;
            break;
          case "denied":
            current.denied = entries;
            break;
        }
      }
    } else if (section === "examples") {
      const pair = /service:\s*([a-z_]+),\s*action:\s*(\S+?)[,\s}]/.exec(line);
      if (pair !== null) examples.push({ service: pair[1] ?? "", action: pair[2] ?? "" });
    }
  }

  return {
    name: scalar("name"),
    description: scalar("description"),
    whenToUse: scalar("whenToUse"),
    inputs,
    services: declared,
    examples
  };
}

test("SKILL.md declares only ids and actions the node actually routes", () => {
  const card = parseSkillCard(readPackageFile("SKILL.md"));

  assert.equal(card.name, SKILL_NAME);
  assert.ok(card.description.length > 40, "the card has to say what it does");
  assert.ok(card.whenToUse.length > 40, "the card has to say when to use it");
  assert.deepEqual([...card.inputs].sort(), [...SKILL_INPUT_FIELDS].sort());

  assert.deepEqual(card.services.map((entry) => entry.id).sort(), [...SERVICE_IDS].sort());

  for (const entry of card.services) {
    const service = entry.id as ServiceId;
    assert.ok(SERVICE_IDS.includes(service), `${entry.id} is not an EngineKind raw value`);
    assert.deepEqual(
      [...entry.actions].sort(),
      [...ROUTES[service].canonical].sort(),
      `${entry.id} must declare exactly the canonical actions the node routes`
    );

    for (const spelling of entry.accepts) {
      const canonical = canonicalAction(service, spelling);
      assert.ok(canonical !== null, `${entry.id} ${spelling} is not a spelling the node routes`);
      assert.equal(
        ROUTES[service].denied.includes(canonical ?? ""),
        false,
        `${entry.id} ${spelling} is a refused action and must not be offered`
      );
      assert.ok(entry.actions.includes(canonical ?? ""), `${entry.id} ${spelling} maps to an undeclared action`);
      assert.equal(entry.actions.includes(spelling), false, `${spelling} is listed twice, as an alias and as itself`);
    }

    for (const alias of entry.also) {
      assert.equal(resolveServiceId(alias), service, `${alias} does not resolve to ${entry.id}`);
    }

    for (const blocked of entry.denied) {
      const canonical = canonicalAction(service, blocked);
      assert.ok(canonical !== null, `${entry.id} ${blocked} is not a spelling the node routes`);
      assert.ok(ROUTES[service].denied.includes(canonical ?? ""), `${entry.id} ${blocked} is not refused by the kernel`);
    }
    assert.deepEqual(
      new Set(entry.denied.map((blocked) => canonicalAction(service, blocked) ?? "")),
      new Set(ROUTES[service].denied),
      `${entry.id} denied spellings do not cover the kernel's blocked set`
    );
  }

  assert.ok(card.examples.length >= 3, "the card must show the host how to call it");
  for (const example of card.examples) {
    const service = resolveServiceId(example.service);
    assert.ok(service !== null, `example service ${example.service} is unknown`);
    const canonical = service === null ? null : canonicalAction(service, example.action);
    assert.ok(canonical !== null, `example action ${example.action} for ${example.service} is unknown`);
    if (service === null || canonical === null) continue;
    assert.equal(
      ROUTES[service].denied.includes(canonical),
      false,
      `example ${example.service} ${example.action} is a refused lockdown call`
    );
  }
});

test("the card offers phantom_sentinel only as a report", () => {
  const card = parseSkillCard(readPackageFile("SKILL.md"));
  const sentinel = card.services.find((entry) => entry.id === "phantom_sentinel");
  assert.ok(sentinel !== undefined);
  assert.deepEqual(sentinel.actions, ["status"]);
  assert.deepEqual(sentinel.accepts, ["probe"]);
  assert.deepEqual([...sentinel.denied].sort(), [...LOCKDOWN_SPELLINGS].sort());

  // The machine-readable block is the declaration: every canonical id and every canonical action of
  // the node's table has to be in it, or the card silently offers a subset of what the node routes.
  const byId = new Map(card.services.map((entry) => [entry.id, entry]));
  assert.deepEqual([...byId.keys()].sort(), [...SERVICE_IDS].sort());
  for (const service of SERVICE_IDS) {
    const entry = byId.get(service);
    assert.ok(entry !== undefined, `the card does not declare ${service}`);
    if (entry === undefined) continue;
    for (const action of ROUTES[service].canonical) {
      assert.ok(entry.actions.includes(action), `the card does not declare ${service} ${action}`);
    }
  }

  const text = readPackageFile("SKILL.md");
  for (const spelling of LOCKDOWN_SPELLINGS) {
    assert.ok(text.includes(`\`${spelling}\``), `the card does not name the blocked spelling ${spelling}`);
  }
});

// MARK: - the two READMEs are one document

function fences(text: string): string[] {
  const blocks: string[] = [];
  let current: string[] | null = null;
  for (const line of text.split("\n")) {
    if (line.startsWith("```")) {
      if (current === null) {
        current = [];
      } else {
        blocks.push(current.join("\n"));
        current = null;
      }
      continue;
    }
    if (current !== null) current.push(line);
  }
  assert.equal(current, null, "an unclosed fence");
  return blocks;
}

function headingCount(text: string): number {
  return text.split("\n").filter((line) => line.startsWith("## ")).length;
}

function citationSet(text: string): string[] {
  return [...new Set([...text.matchAll(/[\w.]+\.swift:\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*/g)].map((match) => match[0]))].sort();
}

function portSet(text: string): string[] {
  return [...new Set([...text.matchAll(/127\.0\.0\.1:(\d+)/g)].map((match) => match[1] ?? ""))].sort();
}

function serviceRows(text: string): string[] {
  return text.split("\n").filter((line) => line.startsWith("| `") && SERVICE_IDS.some((id) => line.includes(`\`${id}\``)));
}

test("the English and Chinese READMEs are structurally one document", () => {
  const english = readPackageFile("README.md");
  const chinese = readPackageFile("README.zh-CN.md");

  assert.equal(headingCount(english), headingCount(chinese), "the two documents no longer have the same sections");
  assert.ok(headingCount(english) >= 10, "both documents must keep their sections");

  const englishFences = fences(english);
  const chineseFences = fences(chinese);
  assert.equal(englishFences.length, chineseFences.length, "the two documents show a different number of blocks");
  assert.ok(englishFences.length >= 4, "both documents must show the commands");
  englishFences.forEach((block, index) => {
    assert.equal(block, chineseFences[index], `fence ${String(index + 1)} differs between the two READMEs`);
  });

  assert.deepEqual(citationSet(english), citationSet(chinese), "the file:line citation sets drifted apart");
  assert.ok(citationSet(english).length >= 10, "every claim keeps its source");
  assert.deepEqual(portSet(english), portSet(chinese), "the port sets drifted apart");
  assert.ok(portSet(english).includes("18920"));

  assert.deepEqual(serviceRows(english), serviceRows(chinese), "the service and action tables drifted apart");
  for (const id of SERVICE_IDS) {
    assert.ok(english.includes(`\`${id}\``), `README.md does not document ${id}`);
    assert.ok(chinese.includes(`\`${id}\``), `README.zh-CN.md does not document ${id}`);
  }
  for (const service of SERVICE_IDS) {
    for (const action of ROUTES[service].canonical) {
      assert.ok(english.includes(`\`${action}\``), `README.md does not document ${service} ${action}`);
      assert.ok(chinese.includes(`\`${action}\``), `README.zh-CN.md does not document ${service} ${action}`);
    }
  }
});

test("the English README stays in English, including its language links", () => {
  const english = readPackageFile("README.md");
  const hanzi = english.split("\n").filter((line) => [...line].some((character) => character >= "\u{4E00}" && character <= "\u{9FFF}"));
  assert.deepEqual(hanzi, [], "README.md may not carry Chinese anywhere, not even in a link label");
  assert.match(english, /\[Chinese\]\(README\.zh-CN\.md\)/, "the English file must offer its twin");
  assert.match(english, /\[Chinese\]\(\.\.\/CONTRACT\.zh-CN\.md\)/, "and the Chinese contract");

  const chinese = readPackageFile("README.zh-CN.md");
  assert.ok(chinese.includes("[English](README.md)"), "the Chinese document must link back");
});

// MARK: - the shipped template

test("the example config is copyable, refuses lockdown, and carries no secret", () => {
  const path = join(packageRoot, "config", "popopx-bridge.example.json");
  const raw = readFileSync(path, "utf8");
  assert.equal(raw.includes(["/Us", "ers/"].join("")), false, "no developer machine path may be committed");
  assert.equal(CONFIG_KEYS.length, 4);

  const loaded = loadConfigFile(path);
  assert.equal(loaded.ok, true);
  if (!loaded.ok) return;
  const config = loaded.config as Partial<ConfigFile>;
  assert.equal(config.allowLockdown, false, "the template must not opt into a physical lockdown");
  assert.equal(config.logRefusals, true);
  assert.equal(config.timeoutMs, 15_000);
  assert.equal(config.handoff, "", "the token comes from the paste or PPX_CONSOLE_TOKEN, never from a file");
  assert.deepEqual(Object.keys(JSON.parse(raw) as Record<string, unknown>).sort(), [...CONFIG_KEYS].sort());
});

test("loadConfigFile refuses shapes this package does not implement", () => {
  const dir = mkdtempSync(join(tmpdir(), "popopx-linger-"));
  try {
    const cases: readonly [string, string, RegExp][] = [
      ["nonObject.json", "[1,2]", /must hold one JSON object/],
      ["badJson.json", "{oops", /is not JSON/],
      ["path.json", JSON.stringify({ handoff: "/tmp/elsewhere/console.json" }), /never a file path/],
      ["timeout.json", JSON.stringify({ timeoutMs: 0 }), /timeoutMs must be an integer/]
    ];
    for (const [name, content, pattern] of cases) {
      const file = join(dir, name);
      writeFileSync(file, content, "utf8");
      const outcome = loadConfigFile(file);
      assert.equal(outcome.ok, false, `${name} must be refused`);
      if (!outcome.ok) assert.match(outcome.reason, pattern);
    }
    const absent = loadConfigFile(join(dir, "missing.json"));
    assert.equal(absent.ok, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// MARK: - house rules, enforced by the suite

test("the package never names the upstream chat daemon and leaves no stubs behind", () => {
  const needles = [["simplex", "chat"].join("-"), ["simplex", "chat"].join(" ")];
  // Every needle is assembled at runtime so this file cannot match its own guard.
  const stubs = [
    ["// TO", "DO"].join(""),
    ["TO", "DO:"].join(""),
    ["implementation omi", "tted"].join(""),
    ["not implemen", "ted"].join(""),
    ["place", "holder"].join(""),
    ["@ts", "-ignore"].join(""),
    ["as", " an", "y"].join("")
  ];
  const files = [
    "package.json",
    "tsconfig.json",
    "SKILL.md",
    "README.md",
    "README.zh-CN.md",
    "config/popopx-bridge.example.json",
    "src/index.ts",
    "src/handlers.ts",
    "src/log.ts",
    "test/skill.test.ts"
  ];

  for (const file of files) {
    const text = readPackageFile(file);
    const lower = text.toLowerCase();
    for (const needle of needles) {
      assert.equal(lower.includes(needle), false, `${file} names the upstream chat daemon; this product's CLI is popopx-chat`);
    }
    for (const stub of stubs) {
      assert.equal(lower.includes(stub.toLowerCase()), false, `${file} carries ${stub}`);
    }
    assert.equal(text.includes(["/Us", "ers/"].join("")), false, `${file} carries a developer machine path`);
    if (file.endsWith(".md")) assert.equal(text.includes("..."), false, `${file} carries an ellipsis`);
  }
});

test("services() is the kernel's own list", () => {
  assert.deepEqual([...services()], [...SERVICE_IDS]);
});

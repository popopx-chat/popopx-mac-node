/**
 * Transport tests for the console client, run against a fake `fetch` so every status the node can
 * answer is exercised without a node: 401, 405, 411, 413, 5xx, a redirect, a truncated body and a
 * refused connection. The retry rules are the point of several of these — the node runs real side
 * effects, so a resend is only allowed when the request demonstrably never arrived.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BridgeError,
  ConsoleClient,
  ROUTE,
  resolveTarget,
  parseWireLine,
  type CommandResult,
  type ConsoleTarget,
  type WireCommand
} from "../src/index.js";

const TOKEN = "AbCdEf0123456789_-xyzABC";

interface Call {
  readonly url: string;
  readonly method: string;
  readonly headers: Record<string, string>;
  readonly body?: string;
}

function target(overrides: Partial<ConsoleTarget> = {}): ConsoleTarget {
  return {
    origin: "http://127.0.0.1:18920",
    host: "127.0.0.1",
    port: 18920,
    token: TOKEN,
    ...overrides
  };
}

function command(): WireCommand {
  const parsed = parseWireLine(`${"::popopx_sys::NODE_CMD::"}shadow_cos::daily::{"tone":"terse"}`);
  assert.equal(parsed.ok, true);
  return (parsed as { command: WireCommand }).command;
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

function responder(
  handler: (call: Call, index: number) => Response | Promise<Response>
): { fetchImpl: typeof fetch; calls: Call[] } {
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

const jsonResponse = (payload: unknown, status = 200): Response =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" }
  });

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

function timeoutError(): Error {
  return Object.assign(new Error("The operation was aborted due to timeout"), { name: "TimeoutError" });
}

test("resolveTarget reads a tokenised console URL", () => {
  const parsed = resolveTarget(`http://127.0.0.1:18920/?t=${TOKEN}`);
  assert.equal(parsed.origin, "http://127.0.0.1:18920");
  assert.equal(parsed.token, TOKEN);
  assert.equal(parsed.port, 18920);
});

test("resolveTarget accepts a bare token with environment defaults", () => {
  const parsed = resolveTarget(TOKEN, { PPX_CONSOLE_TOKEN: "ignored", PPX_CONSOLE_PORT: "19000" });
  assert.equal(parsed.token, TOKEN);
  assert.equal(parsed.port, 19_000, "the pasted value wins over the environment, the port does not");
  const fromEnv = resolveTarget("", { PPX_CONSOLE_TOKEN: TOKEN });
  assert.equal(fromEnv.token, TOKEN);
  assert.equal(fromEnv.port, 18920, "the default port is the node's fixed one");
});

test("resolveTarget refuses anything that is not loopback", () => {
  for (const input of [
    "http://10.0.0.5:18920/?t=x",
    "http://example.com:18920/?t=x",
    "http://169.254.1.1/?t=x"
  ]) {
    assert.throws(
      () => resolveTarget(input),
      (error: unknown) => (error as BridgeError).code === "nonLoopbackTarget",
      `${input} must be refused`
    );
  }
  assert.throws(
    () => resolveTarget("", { PPX_CONSOLE_HOST: "0.0.0.0", PPX_CONSOLE_TOKEN: TOKEN }),
    (error: unknown) => (error as BridgeError).code === "nonLoopbackTarget"
  );
  assert.throws(
    () => resolveTarget("", { PPX_CONSOLE_PORT: "0", PPX_CONSOLE_TOKEN: TOKEN }),
    (error: unknown) => (error as BridgeError).code === "nonLoopbackTarget"
  );
  assert.throws(
    () => resolveTarget("", { PPX_CONSOLE_PORT: "notaport", PPX_CONSOLE_TOKEN: TOKEN }),
    (error: unknown) => (error as BridgeError).code === "nonLoopbackTarget"
  );
});

test("https is refused because the console is plain HTTP on loopback", () => {
  assert.throws(
    () => resolveTarget(`https://127.0.0.1:18920/?t=${TOKEN}`),
    (error: unknown) => (error as BridgeError).code === "nonLoopbackTarget"
  );
});

test("no handoff at all is a typed token error, not a crash", () => {
  assert.throws(
    () => resolveTarget("", {}),
    (error: unknown) => (error as BridgeError).code === "tokenRejected"
  );
  assert.throws(
    () => resolveTarget("http://127.0.0.1:18920/"),
    (error: unknown) => (error as BridgeError).code === "tokenRejected"
  );
});

test("localhost and ::1 are loopback", () => {
  assert.equal(resolveTarget("http://localhost:18920/?t=x").host, "localhost");
  assert.equal(resolveTarget("http://[::1]:18920/?t=x").host, "[::1]");
});

test("invoke posts kind, action and payload with the token header", async () => {
  const { fetchImpl, calls } = responder(() => jsonResponse(resultFixture()));
  const client = new ConsoleClient({ target: target(), fetchImpl });
  const result = await client.invoke(command());
  assert.equal(result.headline, "briefing ready");
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.url, `http://127.0.0.1:18920${ROUTE.engineInvoke}`);
  assert.equal(calls[0]?.method, "POST");
  assert.equal(calls[0]?.headers["x-ppx-token"], TOKEN);
  assert.equal(calls[0]?.headers["content-type"], "application/json");
  const body = JSON.parse(calls[0]?.body ?? "{}") as Record<string, unknown>;
  assert.deepEqual(body, { kind: "shadow_cos", action: "briefing", payload: { tone: "terse" } });
  // The alias was canonicalised before the socket opened, so the node never sees `daily`.
  assert.equal(body["action"], "briefing");
});

test("injectRaw sends the field the node decodes, which is named text", async () => {
  const { fetchImpl, calls } = responder(() => jsonResponse(resultFixture()));
  const client = new ConsoleClient({ target: target(), fetchImpl });
  const line = "::popopx_sys::NODE_CMD::chrono_ark::list::{}";
  await client.injectRaw(line);
  assert.equal(calls[0]?.url, `http://127.0.0.1:18920${ROUTE.command}`);
  assert.deepEqual(JSON.parse(calls[0]?.body ?? "{}"), { text: line });
});

test("a lockdown line never reaches the socket, through either entry point", async () => {
  let calls = 0;
  const { fetchImpl } = responder(() => {
    calls += 1;
    return jsonResponse(resultFixture());
  });
  const client = new ConsoleClient({ target: target(), fetchImpl });
  const outcome = await client.runLine("::popopx_sys::NODE_CMD::phantom_sentinel::lockdown::{}");
  assert.ok(outcome.error, "runLine must report the refusal");
  assert.equal(outcome.error?.code, "lockdownDenied");
  await assert.rejects(
    () => client.injectRaw("::popopx_sys::NODE_CMD::phantom_sentinel::lock_all::{}"),
    (error: unknown) => (error as BridgeError).code === "lockdownDenied"
  );
  assert.equal(calls, 0, "a refused command must not open a connection");
});

test("the opt-in path needs both the flag and a secret, and still only sends once", async () => {
  const { fetchImpl, calls } = responder(() => jsonResponse(resultFixture()));
  const client = new ConsoleClient({
    target: target(),
    fetchImpl,
    allowLockdown: true,
    secret: "0123456789abcdef"
  });
  const parsed = parseWireLine("::popopx_sys::NODE_CMD::phantom_sentinel::lockdown::{}");
  assert.equal(parsed.ok, true);
  await client.invoke((parsed as { command: WireCommand }).command);
  assert.equal(calls.length, 1);
  assert.equal(JSON.parse(calls[0]?.body ?? "{}")["action"], "lockdown");

  const strict = new ConsoleClient({ target: target(), fetchImpl, allowLockdown: true });
  await assert.rejects(
    () => strict.invoke((parsed as { command: WireCommand }).command),
    (error: unknown) => (error as BridgeError).code === "secretRequired"
  );
});

test("401 is a typed tokenRejected that is safe to report but not to retry", async () => {
  const { fetchImpl, calls } = responder(() => textResponse("401 unauthorized: missing or wrong token", 401));
  const client = new ConsoleClient({ target: target(), fetchImpl });
  await assert.rejects(
    () => client.invoke(command()),
    (error: unknown) => {
      const bridgeError = error as BridgeError;
      assert.equal(bridgeError.code, "tokenRejected");
      assert.equal(bridgeError.status, 401);
      assert.equal(bridgeError.outcomeUnknown, false);
      assert.ok(!bridgeError.message.includes(TOKEN), "the secret must not be echoed back");
      assert.ok(!String(bridgeError.detail).includes(TOKEN), "the detail must not echo the secret either");
      return true;
    }
  );
  // A separate client, so the count below is the retry path alone rather than this test's first call.
  const retrying = responder(() => textResponse("401 unauthorized: missing or wrong token", 401));
  const secondClient = new ConsoleClient({ target: target(), fetchImpl: retrying.fetchImpl });
  await assert.rejects(() => secondClient.invokeWithRetry(command()));
  assert.equal(retrying.calls.length, 1, "a rejected token is not a transport hiccup");
  assert.equal(calls.length, 1);
});

test("405, 411 and 413 keep their own codes", async () => {
  for (const [status, code] of [
    [405, "methodNotAllowed"],
    [411, "lengthRequired"],
    [413, "payloadTooLarge"]
  ] as const) {
    const { fetchImpl } = responder(() => textResponse(`http ${status}`, status));
    const client = new ConsoleClient({ target: target(), fetchImpl });
    await assert.rejects(
      () => client.invoke(command()),
      (error: unknown) => {
        assert.equal((error as BridgeError).code, code);
        assert.equal((error as BridgeError).status, status);
        assert.equal((error as BridgeError).outcomeUnknown, false, `${status} was rejected before execution`);
        return true;
      }
    );
  }
});

test("a 5xx is nodeBusy and is never resent", async () => {
  const { fetchImpl, calls } = responder(() => textResponse("server error", 503));
  const client = new ConsoleClient({ target: target(), fetchImpl });
  await assert.rejects(
    () => client.invokeWithRetry(command()),
    (error: unknown) => {
      assert.equal((error as BridgeError).code, "nodeBusy");
      assert.equal((error as BridgeError).outcomeUnknown, true);
      return true;
    }
  );
  assert.equal(calls.length, 1, "the node may have run the command; a second attempt could run it twice");
});

test("a refused connection is the one failure that may be retried", async () => {
  const { fetchImpl, calls } = responder((_call, index) => {
    if (index === 0) return Promise.reject(refusedConnection());
    return jsonResponse(resultFixture());
  });
  const client = new ConsoleClient({ target: target(), fetchImpl });
  const result = await client.invokeWithRetry(command());
  assert.equal(result.ok, true);
  assert.equal(calls.length, 2);
});

test("a timeout is not retried, because the answer arriving late is not proof nothing ran", async () => {
  const { fetchImpl, calls } = responder(() => Promise.reject(timeoutError()));
  const client = new ConsoleClient({ target: target(), fetchImpl, timeoutMs: 50 });
  await assert.rejects(
    () => client.invokeWithRetry(command()),
    (error: unknown) => {
      assert.equal((error as BridgeError).code, "nodeUnreachable");
      assert.equal((error as BridgeError).outcomeUnknown, true);
      return true;
    }
  );
  assert.equal(calls.length, 1);
});

test("a redirect is refused rather than followed", async () => {
  const { fetchImpl } = responder(() => new Response(null, { status: 302, headers: { location: "http://example.com/" } }));
  const client = new ConsoleClient({ target: target(), fetchImpl });
  await assert.rejects(
    () => client.invoke(command()),
    (error: unknown) => (error as BridgeError).code === "badResponse"
  );
});

test("a 404 on the engine route says the listener is not the node", async () => {
  const { fetchImpl } = responder(() => textResponse("no such route", 404));
  const client = new ConsoleClient({ target: target(), fetchImpl });
  await assert.rejects(
    () => client.invoke(command()),
    (error: unknown) => {
      const bridgeError = error as BridgeError;
      assert.equal(bridgeError.status, 404);
      assert.match(bridgeError.message, /engine\/invoke route/, "the operator needs to be told which route is missing");
      return true;
    }
  );
});

test("a body that is not JSON is a badResponse, and a long body is not truncated", async () => {
  // Counted, not routed by URL: both calls hit the same endpoint and only the first one lies.
  let answers = 0;
  const { fetchImpl } = responder(() => {
    answers += 1;
    return answers === 1
      ? textResponse("rendered html instead of json")
      : jsonResponse(resultFixture({ body: "x".repeat(4_000) }));
  });
  const client = new ConsoleClient({ target: target(), fetchImpl });
  await assert.rejects(
    () => client.invoke(command()),
    (error: unknown) => (error as BridgeError).code === "badResponse"
  );
  const result = await client.invoke(command());
  assert.equal(result.body.length, 4_000, "a result body must survive the whole way to the caller");
});

test("two concurrent commands are refused, not queued", async () => {
  let release!: (value: Response) => void;
  const gate = new Promise<Response>((resolve) => {
    release = resolve;
  });
  const { fetchImpl, calls } = responder(() => gate);
  const client = new ConsoleClient({ target: target(), fetchImpl });
  const first = client.invoke(command());
  await assert.rejects(
    () => client.invoke(command()),
    (error: unknown) => (error as BridgeError).code === "inFlightLimit"
  );
  release(jsonResponse(resultFixture()));
  await first;
  assert.equal(calls.length, 1);

  // The slot is released on the failure path too, or a bridge would wedge after one bad answer.
  const failing = responder(() => Promise.reject(refusedConnection()));
  const wedged = new ConsoleClient({ target: target(), fetchImpl: failing.fetchImpl });
  await assert.rejects(() => wedged.invoke(command()));
  await assert.rejects(() => wedged.invoke(command()));
  assert.equal(failing.calls.length, 2, "the second call must be attempted, not blocked by a stale slot");
});

test("the token is never printed by the client", () => {
  const client = new ConsoleClient({ target: target(), fetchImpl: responder(() => jsonResponse({})).fetchImpl });
  assert.ok(!client.tokenFingerprint.includes(TOKEN));
  assert.match(client.tokenFingerprint, /ends .{4}$/);
  assert.equal(client.origin, "http://127.0.0.1:18920");
});

test("the event URL carries the token as a query parameter, which is the only way an EventSource can", async () => {
  let seen = "";
  const { fetchImpl } = responder((call) => {
    seen = call.url;
    return new Response("", { status: 200 });
  });
  const client = new ConsoleClient({ target: target(), fetchImpl });
  const stream = client.events(undefined, { maxReconnects: 0 });
  for await (const _ of stream) {
    // Empty body: the stream ends immediately.
  }
  assert.ok(seen.startsWith(`http://127.0.0.1:18920${ROUTE.events}?t=`), seen);
  assert.ok(seen.includes(encodeURIComponent(TOKEN)));
});

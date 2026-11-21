/**
 * SSE reader tests. The frames here are copied byte-for-byte in shape from
 * `WEBSSEChannel.frame(for:)` in `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift`,
 * including the `retry:` preamble and the `: ppx heartbeat` comment, because the reader has to
 * survive a frame split across network chunks.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BridgeError,
  EventStream,
  decodeFrame,
  splitFrames,
  type NodeEvent
} from "../src/index.js";

const TOKEN = "streamtoken0123456789ABCDEF";

const encoder = new TextEncoder();

function streamOf(chunks: readonly string[], flush = false): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      if (!flush) controller.close();
    }
  });
}

function frameStream(chunks: readonly string[], init: { status?: number } = {}): Response {
  return new Response(streamOf(chunks), {
    status: init.status ?? 200,
    headers: { "content-type": "text/event-stream" }
  });
}

function eventFrame(channel: string, message: string, level = "info"): string {
  const payload = { channel, level, message, at: "2026-11-21T09:10:11Z", payload: { k: 1 } };
  return `event: ${channel}\ndata: ${JSON.stringify(payload)}\n\n`;
}

async function collect(stream: EventStream): Promise<NodeEvent[]> {
  const seen: NodeEvent[] = [];
  for await (const event of stream) seen.push(event);
  return seen;
}

test("splitFrames finds frame boundaries and keeps the remainder", () => {
  const text = "retry: 3000\n\n" + eventFrame("engine", "one") + "event: result\ndata: {\"chan";
  const split = splitFrames(text);
  assert.equal(split.frames.length, 2);
  assert.equal(split.frames[0]?.retryMs, 3_000);
  assert.deepEqual(split.frames[0]?.data, []);
  assert.equal(split.frames[1]?.event, "engine");
  assert.equal(split.rest, 'event: result\ndata: {"chan');
});

test("splitFrames also accepts the CRLF boundary", () => {
  const split = splitFrames('event: system\r\ndata: {"channel":"system"}\r\n\r\n');
  assert.equal(split.frames.length, 1);
  const decoded = decodeFrame(split.frames[0] ?? { event: null, data: [], retryMs: null });
  assert.equal(decoded.ok, true);
});

test("decodeFrame reads the fields the node writes and rejects what it does not", () => {
  const good = decodeFrame({
    event: "sentinel",
    data: ['{"channel":"sentinel","level":"warn","message":"locked","at":"2026-11-21T09:10:11Z","payload":{}}'],
    retryMs: null
  });
  assert.equal(good.ok, true);
  assert.equal(good.event.channel, "sentinel");
  assert.equal(good.event.level, "warn");
  assert.equal(good.event.message, "locked");

  // The `event:` line is the fallback when a payload omits the channel, never a replacement for it.
  const noChannel = decodeFrame({ event: "mesh", data: ['{"message":"hi"}'], retryMs: null });
  assert.equal(noChannel.ok, true);
  assert.equal(noChannel.event.channel, "mesh");
  assert.equal(noChannel.event.level, "info", "a missing level defaults instead of crashing a plugin");

  for (const bad of [
    { event: "engine", data: [], retryMs: null },
    { event: "engine", data: ["not json"], retryMs: null },
    { event: "engine", data: ["[1,2]"], retryMs: null },
    { event: null, data: ['{"message":"no channel anywhere"}'], retryMs: null }
  ]) {
    const decoded = decodeFrame(bad);
    assert.equal(decoded.ok, false, `${JSON.stringify(bad.data)} must not decode`);
  }

  // The server scrubs newlines out of the JSON, so a multi-line data field is unusual but legal SSE.
  const multi = decodeFrame({ event: "result", data: ['{"channel":"result",', '"message":"m"}'], retryMs: null });
  assert.equal(multi.ok, true);
  assert.equal(multi.event.message, "m");
});

test("a heartbeat comment and the retry preamble produce no event", async () => {
  const stream = new EventStream({
    url: `http://127.0.0.1:18920/api/events?t=${TOKEN}`,
    fetchImpl: (async () =>
      frameStream([
        "retry: 3000\n\n",
        ": ppx heartbeat\n\n",
        eventFrame("bridge", "connected"),
        ": ppx heartbeat\n\n"
      ])) as unknown as typeof fetch,
    maxReconnects: 0
  });
  const seen = await collect(stream);
  assert.equal(seen.length, 1);
  assert.equal(seen[0]?.channel, "bridge");
  assert.equal(seen[0]?.message, "connected");
});

test("a frame split across three chunks is reassembled", async () => {
  const first = eventFrame("engine", "alpha");
  const second = eventFrame("result", "beta");
  const cut = Math.floor(second.length / 2);
  const chunks = [first.slice(0, 7), first.slice(7, 20), first.slice(20) + second.slice(0, cut), second.slice(cut)];
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    fetchImpl: (async () => frameStream(chunks)) as unknown as typeof fetch,
    maxReconnects: 0
  });
  const seen = await collect(stream);
  assert.deepEqual(
    seen.map((event) => event.message),
    ["alpha", "beta"]
  );
});

test("a multibyte payload split mid-UTF-8 sequence still decodes", async () => {
  const text = eventFrame("system", "广播已生成");
  const frame = encoder.encode(text);
  const at = text.indexOf("广");
  assert.ok(at > 0, "the CJK run must be inside the frame");
  const cut = encoder.encode(text.slice(0, at)).length; // byte offset of 广, which is E5 B9 BF
  // One byte into the sequence: the decoder must hold E5 and finish it from the next chunk.
  const head = frame.slice(0, cut + 1);
  const tail = frame.slice(cut + 1);
  assert.equal(head.at(-1), 0xe5, "the cut has to land mid-sequence to prove anything");
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    fetchImpl: (async () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(head);
            controller.enqueue(tail);
            controller.close();
          }
        }),
        { status: 200 }
      )) as unknown as typeof fetch,
    maxReconnects: 0
  });
  const seen = await collect(stream);
  assert.equal(seen.length, 1);
  assert.equal(seen[0]?.message, "广播已生成");
});

test("a 401 stops the reader instead of reconnecting with a dead token", async () => {
  let opens = 0;
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=expired",
    fetchImpl: (async () => {
      opens += 1;
      return new Response("401 unauthorized: missing or wrong token", { status: 401 });
    }) as unknown as typeof fetch,
    maxReconnects: 5
  });
  await assert.rejects(
    () => collect(stream),
    (error: unknown) => (error as BridgeError).code === "tokenRejected"
  );
  assert.equal(opens, 1);
});

test("passes that deliver nothing are retried up to the limit, then reported", async () => {
  let opens = 0;
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    fetchImpl: (async () => {
      opens += 1;
      return frameStream([": ppx heartbeat\n\n"]); // opens fine, hands over no event
    }) as unknown as typeof fetch,
    maxReconnects: 2,
    initialBackoffMs: 1
  });
  await assert.rejects(
    () => collect(stream),
    (error: unknown) => {
      assert.match((error as BridgeError).message, /without delivering an event/);
      return (error as BridgeError).code === "nodeUnreachable";
    }
  );
  assert.equal(opens, 3, "the first pass plus two reconnects");
});

test("a pass that delivered events restarts the budget, because the node ends a full stream on purpose", async () => {
  let opens = 0;
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    fetchImpl: (async () => {
      opens += 1;
      if (opens <= 3) return frameStream([eventFrame("engine", `pass ${opens}`)]);
      return frameStream([": ppx heartbeat\n\n"]); // alive, with nothing to hand over
    }) as unknown as typeof fetch,
    maxReconnects: 1,
    initialBackoffMs: 1
  });
  const seen: NodeEvent[] = [];
  await assert.rejects(
    async () => {
      for await (const event of stream) seen.push(event);
    },
    (error: unknown) => (error as BridgeError).code === "nodeUnreachable"
  );
  assert.deepEqual(
    seen.map((event) => event.message),
    ["pass 1", "pass 2", "pass 3"],
    "three delivering passes must not consume a budget of one retry"
  );
  assert.equal(opens, 5, "one empty pass is forgiven, the second is reported");
});

test("close() ends iteration without an error", async () => {
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    fetchImpl: (async (_url: string | URL, init?: RequestInit) =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(encoder.encode(eventFrame("engine", "one")));
            // Then nothing. A real fetch body errors when its signal aborts, and the fake has to
            // behave the same way or close() would leave the read outstanding forever.
            const signal = init?.signal;
            signal?.addEventListener(
              "abort",
              () => controller.error(new Error("aborted by close()")),
              { once: true }
            );
          }
        }),
        { status: 200 }
      )) as unknown as typeof fetch,
    maxReconnects: 10,
    initialBackoffMs: 1
  });
  const seen: NodeEvent[] = [];
  for await (const event of stream) {
    seen.push(event);
    stream.close();
  }
  assert.equal(seen.length, 1);
});

test("an abort signal ends the pass and stops reconnecting", async () => {
  const controller = new AbortController();
  let opens = 0;
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    signal: controller.signal,
    fetchImpl: (async () => {
      opens += 1;
      controller.abort();
      return frameStream([eventFrame("engine", "then aborted")]);
    }) as unknown as typeof fetch,
    maxReconnects: 10,
    initialBackoffMs: 1
  });
  const seen = await collect(stream);
  assert.equal(opens, 1);
  assert.equal(seen.length, 1, "events already delivered are still returned");
});

test("a non-event-stream answer is a typed failure, not an empty success", async () => {
  for (const [status, code] of [
    [500, "nodeUnreachable"],
    [204, "noBody"]
  ] as const) {
    const stream = new EventStream({
      url: "http://127.0.0.1:18920/api/events?t=x",
      fetchImpl: (async () => new Response(status === 204 ? null : "nope", { status })) as unknown as typeof fetch,
      maxReconnects: 0
    });
    if (status === 204) {
      // 204 answers with no body, so the reader stops without inventing an event.
      const seen = await collect(stream);
      assert.equal(seen.length, 0);
      continue;
    }
    await assert.rejects(
      () => collect(stream),
      (error: unknown) => (error as BridgeError).code === code
    );
  }
});

test("a frame whose data is not JSON is reported, not skipped", async () => {
  const stream = new EventStream({
    url: "http://127.0.0.1:18920/api/events?t=x",
    fetchImpl: (async () => frameStream(['event: engine\ndata: {"channel":\n\n'])) as unknown as typeof fetch,
    maxReconnects: 0
  });
  await assert.rejects(
    () => collect(stream),
    (error: unknown) => (error as BridgeError).code === "badResponse"
  );
});

/**
 * Grammar and policy tests for the wire layer. The corpus in `fixtures/wire-vectors.json` is the
 * same one `Tests/PopopxMacNodeTests/MacNodeContractTests.swift` grades the Swift parser against,
 * so a drift in either runtime fails here rather than in front of a node.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  COMMAND_PREFIX,
  MAX_SIGNAL_PAYLOAD_CHARACTERS,
  ROUTES,
  SERVICE_IDS,
  assertSendable,
  canonicalAction,
  graphemeCount,
  listServices,
  normaliseAction,
  normaliseServiceId,
  parseWireLine,
  renderWireLine,
  resolveServiceId,
  type BridgeError,
  type ParseResult,
  type WireCommand
} from "../src/index.js";

interface ExpectedBridge {
  readonly ok: boolean;
  readonly code?: string;
  readonly serviceId?: string;
  readonly action?: string;
  readonly payload?: string;
  readonly denied?: boolean;
}

interface Vector {
  readonly name: string;
  readonly line: string;
  readonly nodeParse: string;
  readonly bridge: ExpectedBridge;
  readonly note?: string;
}

interface Fixture {
  readonly maxSignalPayloadCharacters: number;
  readonly vectors: readonly Vector[];
}

function readFixture(): Fixture {
  // Compiled to dist/test/, so the corpus lives two directories up; run from source it is one.
  const candidates = ["../../test/fixtures/", "../fixtures/"] as const;
  for (const dir of candidates) {
    const path = fileURLToPath(new URL(dir + "wire-vectors.json", import.meta.url));
    try {
      return JSON.parse(readFileSync(path, "utf8")) as Fixture;
    } catch {
      // Try the next layout.
    }
  }
  throw new Error(`wire-vectors.json not found relative to ${import.meta.url}`);
}

const fixture = readFixture();

test("the corpus agrees with the constants it is meant to grade", () => {
  assert.equal(fixture.maxSignalPayloadCharacters, MAX_SIGNAL_PAYLOAD_CHARACTERS);
  assert.ok(fixture.vectors.length >= 25, `only ${fixture.vectors.length} vectors in the corpus`);
  for (const vector of fixture.vectors) {
    assert.ok(vector.name.length > 0);
    assert.ok(vector.line.length > 0, `${vector.name}: empty line`);
    assert.ok(
      vector.nodeParse === "accept" || vector.nodeParse === "reject",
      `${vector.name}: nodeParse must be accept or reject, got ${vector.nodeParse}`
    );
    if (vector.bridge.serviceId !== undefined) {
      assert.ok(
        (SERVICE_IDS as readonly string[]).includes(vector.bridge.serviceId),
        `${vector.name}: expected serviceId ${vector.bridge.serviceId} is not a known id`
      );
    }
  }
});

test("every vector matches the mirror of NodeWire.parseCommand", () => {
  for (const vector of fixture.vectors) {
    const result = parseWireLine(vector.line);
    if (!vector.bridge.ok) {
      assert.equal(result.ok, false, `${vector.name}: expected a refusal`);
      const failure = result as Exclude<ParseResult, { ok: true }>;
      assert.equal(failure.code, vector.bridge.code, `${vector.name}: wrong refusal code`);
      assert.ok(failure.reason.length > 0, `${vector.name}: refusal without a reason`);
      continue;
    }
    assert.equal(result.ok, true, `${vector.name}: ${"code" in result ? result.code : "rejected"}`);
    const command = (result as { command: WireCommand }).command;
    assert.equal(command.serviceId, vector.bridge.serviceId, `${vector.name}: wrong service`);
    assert.equal(command.action, vector.bridge.action, `${vector.name}: wrong canonical action`);
    if (vector.bridge.payload !== undefined) {
      assert.equal(command.payload, vector.bridge.payload, `${vector.name}: payload was altered`);
    }
    if (vector.bridge.denied !== undefined) {
      assert.equal(command.denied, vector.bridge.denied, `${vector.name}: wrong denied flag`);
    }
  }
});

test("the bridge column is stricter than the wire column where it must be", () => {
  const diverging = fixture.vectors.filter(
    (vector) =>
      (vector.nodeParse === "accept" && !vector.bridge.ok) ||
      (vector.nodeParse === "reject" && vector.bridge.ok)
  );
  assert.ok(diverging.length >= 8, `expected the documented divergence to cover several vectors, got ${diverging.length}`);
  for (const vector of diverging) {
    assert.ok(
      (vector.note ?? "").length > 0,
      `${vector.name}: the two columns disagree, so the corpus must say why`
    );
  }
});

test("the payload budget charges the two leading segments", () => {
  // morning_tv (10) + digest (6) + two separators = 18 graphemes charged against the ceiling.
  const budget = MAX_SIGNAL_PAYLOAD_CHARACTERS - ("morning_tv".length + "digest".length + 2);
  assert.equal(budget, 1_006);
  assert.equal(budget, fixture.maxSignalPayloadCharacters - 18);

  const fit = `{"d":"${"x".repeat(budget - 8)}"}`;
  assert.equal(graphemeCount(fit), budget);
  const ok = parseWireLine(`${COMMAND_PREFIX}morning_tv::digest::${fit}`);
  assert.equal(ok.ok, true);

  const over = `{"d":"${"x".repeat(budget - 7)}"}`;
  assert.equal(graphemeCount(over), budget + 1);
  const bad = parseWireLine(`${COMMAND_PREFIX}morning_tv::digest::${over}`);
  assert.equal(bad.ok, false);
  assert.equal((bad as { code: string }).code, "payloadBudget");
});

test("counting UTF-16 units instead of graphemes would reject a payload the node accepts", () => {
  // "e" + U+0301 is one Swift `Character` and two JS UTF-16 code units. Written with the escape on
  // purpose: a precomposed é in this file would be one unit and prove nothing.
  const sequences = 990;
  const wrapper = 8; // {"d":" … "}
  const payload = `{"d":"${"e\u0301".repeat(sequences)}"}`;
  assert.equal(graphemeCount(payload), sequences + wrapper);
  assert.equal(payload.length, sequences * 2 + wrapper);
  assert.ok(payload.length > MAX_SIGNAL_PAYLOAD_CHARACTERS, `${payload.length} should overshoot`);
  assert.ok(sequences + wrapper <= MAX_SIGNAL_PAYLOAD_CHARACTERS - 18, "the grapheme count must fit the budget");
  const result = parseWireLine(`${COMMAND_PREFIX}morning_tv::digest::${payload}`);
  assert.equal(result.ok, true, "998 graphemes fit a 1 006 budget even though 1 988 code units do not");
});

test("denied actions parse, and are stopped by the policy gate", () => {
  const result = parseWireLine(`${COMMAND_PREFIX}phantom_sentinel::lockdown::{}`);
  assert.equal(result.ok, true);
  const command = (result as { command: WireCommand }).command;
  assert.equal(command.denied, true);
  assert.equal(command.action, "lockdown");

  assert.throws(
    () => assertSendable(command, {}),
    (error: unknown) => (error as BridgeError).code === "lockdownDenied"
  );
  assert.throws(
    () => assertSendable(command, { allowLockdown: true, secret: "short" }),
    (error: unknown) => (error as BridgeError).code === "secretRequired"
  );
  assert.doesNotThrow(() => assertSendable(command, { allowLockdown: true, secret: "0123456789abcdef" }));

  // Opting in without a secret is still a refusal, never a silent pass.
  assert.throws(
    () => assertSendable(command, { allowLockdown: true }),
    (error: unknown) => (error as BridgeError).code === "secretRequired"
  );

  const harmless = parseWireLine(`${COMMAND_PREFIX}phantom_sentinel::status::{}`);
  assert.equal(harmless.ok, true);
  assert.doesNotThrow(() => assertSendable((harmless as { command: WireCommand }).command, {}));
});

test("every trigger that reaches the node's lockdown routine is denied by the bridge", () => {
  for (const spelling of ["lockdown", "lock", "lock_all", "sentinel", "🔒", "LOCK_ALL", "Lock Down"]) {
    const normalised = normaliseAction(spelling);
    const canonical = canonicalAction("phantom_sentinel", spelling);
    if (normalised === "lock_down") {
      // The node folds spaces, so "Lock Down" becomes "lock_down", which its switch does not match;
      // it lands in `unsupported` instead. The bridge must not invent a denial for it either.
      assert.equal(canonical, null, `${spelling}: unexpectedly resolved`);
      continue;
    }
    assert.equal(canonical, "lockdown", `${spelling}: must canonicalise to lockdown`);
    const result = parseWireLine(`${COMMAND_PREFIX}phantom_sentinel::${spelling}::{}`);
    assert.equal(result.ok, true, `${spelling}: must parse`);
    assert.equal((result as { command: WireCommand }).command.denied, true, `${spelling}: must be denied`);
  }
});

test("phantom_sentinel is the only service with a denied action", () => {
  for (const entry of listServices()) {
    if (entry.id === "phantom_sentinel") {
      assert.deepEqual([...entry.denied], ["lockdown"]);
      assert.deepEqual([...entry.actions], ["status"]);
    } else {
      assert.deepEqual([...entry.denied], [], `${entry.id} declares denials it should not`);
      assert.ok(entry.actions.length > 0, `${entry.id} has no canonical action`);
    }
  }
});

test("alias tables resolve inside their own service and nowhere else", () => {
  for (const id of SERVICE_IDS) {
    const table = ROUTES[id];
    const canonicalNames = new Set<string>(table.canonical);
    // A denied name is a real route in the node — the bridge just refuses to take it — so the
    // canonical list of a service with denials is deliberately narrower than its routing table.
    const routable = new Set<string>([...table.canonical, ...table.denied]);
    for (const [spelling, target] of Object.entries(table.aliases)) {
      assert.ok(routable.has(target), `${id}: alias ${spelling} points at ${target}, which is neither canonical nor denied`);
      assert.equal(canonicalAction(id, spelling), target, `${id}: ${spelling} resolves twice, differently`);
    }
    for (const name of table.canonical) {
      assert.equal(canonicalAction(id, name), name, `${id}: canonical ${name} does not resolve to itself`);
    }
    // A denied name must still be *routable* — that is the whole reason it needs denying — and must
    // never also be offered, or the bridge would deny one action while sending it under another name.
    for (const denied of table.denied) {
      assert.equal(canonicalAction(id, denied), denied, `${id}: denied ${denied} is not routable in the node`);
      assert.ok(!canonicalNames.has(denied), `${id}: ${denied} is both offered and denied`);
    }
  }
});

test("service ids and aliases fold the way engine(for:) does", () => {
  assert.equal(SERVICE_IDS.length, 10);
  for (const id of SERVICE_IDS) {
    assert.equal(resolveServiceId(id), id);
    assert.equal(resolveServiceId(id.toUpperCase()), id, `${id}: case must fold`);
    assert.equal(resolveServiceId(id.replaceAll("_", "-")), id, `${id}: dashes must fold`);
    assert.equal(resolveServiceId(`  ${id}  `), id, `${id}: padding must trim`);
  }
  assert.equal(resolveServiceId("warroom"), "zero_trust_warroom");
  assert.equal(resolveServiceId("chief_of_staff"), "shadow_cos");
  assert.equal(resolveServiceId("lockdown"), "phantom_sentinel");
  assert.equal(resolveServiceId("gop_watermark"), "zero_trust_warroom");
  assert.equal(normaliseServiceId("Zero-Trust_Warroom"), "zero_trust_warroom");
  assert.equal(normaliseAction("  Red Packet "), "red_packet");
  assert.equal(resolveServiceId("nonexistent_engine"), null);
  assert.equal(resolveServiceId(""), null);
});

test("renderWireLine is stable under a second parse", () => {
  const source = `${COMMAND_PREFIX}studio::sanitize::{"file":"a.png","tag":"x::y"}`;
  const first = parseWireLine(source);
  assert.equal(first.ok, true);
  const command = (first as { command: WireCommand }).command;
  assert.equal(command.serviceId, "zerotrace_studio");
  assert.equal(command.action, "process");
  const rendered = renderWireLine(command);
  assert.equal(rendered, `${COMMAND_PREFIX}zerotrace_studio::process::{"file":"a.png","tag":"x::y"}`);
  const second = parseWireLine(rendered);
  assert.equal(second.ok, true);
  const again = (second as { command: WireCommand }).command;
  assert.equal(again.action, command.action);
  assert.equal(again.serviceId, command.serviceId);
  assert.equal(again.payload, command.payload);
  assert.equal(renderWireLine(again), rendered, "render must be idempotent");
});

test("the invoke body is the shape WEBEngineInvokeRequest decodes", () => {
  const result = parseWireLine(`${COMMAND_PREFIX}ark::store::{"until":"2026-12-01T00:00:00Z"}`);
  assert.equal(result.ok, true);
  const command = (result as { command: WireCommand }).command;
  assert.equal(command.serviceId, "chrono_ark");
  assert.equal(command.action, "seal");
  assert.deepEqual(command.invokeBody, {
    kind: "chrono_ark",
    action: "seal",
    payload: { until: "2026-12-01T00:00:00Z" }
  });
  // A JSON-object payload is required, so re-serialising the body cannot produce `"payload": "…"`.
  assert.equal(typeof command.invokeBody.payload, "object");
});

test("a malformed line is refused with the code that names the fault", () => {
  const cases: readonly (readonly [string, string])[] = [
    ["no prefix at all", "malformedCommand"],
    [`${COMMAND_PREFIX}shadow_cos`, "malformedCommand"],
    [`${COMMAND_PREFIX}::briefing::{}`, "malformedCommand"],
    [`${COMMAND_PREFIX}shadow_cos::::{}`, "emptyAction"],
    [`${COMMAND_PREFIX}made_up::briefing::{}`, "unknownService"]
  ];
  for (const [line, code] of cases) {
    const result = parseWireLine(line);
    assert.equal(result.ok, false, `${line}: should be refused`);
    assert.equal((result as { code: string }).code, code, `${line}: wrong code`);
  }
});

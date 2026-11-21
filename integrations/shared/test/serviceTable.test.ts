/**
 * The committed `service-table.json` is the interface between this package and the Swift test target:
 * `IntegrationsContractTests` grades it against the node's own `dispatch` switch, so it must say exactly
 * what `ROUTES` says right now. Regenerate with `npm run build && npm run export:table`.
 *
 * The checks below are written against `ROUTES` rather than against the generator, so a drift in either
 * the table or the export script fails here instead of silently shipping a stale fixture.
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
  listServices
} from "../src/index.js";

interface ExportedService {
  readonly canonical: readonly string[];
  readonly denied: readonly string[];
  readonly actions: Readonly<Record<string, readonly string[]>>;
}

interface ExportedTable {
  readonly commandPrefix: string;
  readonly maxSignalPayloadCharacters: number;
  readonly services: Readonly<Record<string, ExportedService>>;
  readonly offered: readonly { readonly id: string; readonly actions: readonly string[]; readonly denied: readonly string[] }[];
}

function readTable(): ExportedTable {
  const candidates = ["../../test/fixtures/", "../fixtures/"] as const;
  for (const dir of candidates) {
    try {
      return JSON.parse(
        readFileSync(fileURLToPath(new URL(dir + "service-table.json", import.meta.url)), "utf8")
      ) as ExportedTable;
    } catch {
      // Try the next layout: run from source the fixture sits one directory up.
    }
  }
  throw new Error(`service-table.json not found relative to ${import.meta.url}`);
}

const table = readTable();

const sorted = (values: Iterable<string>): string[] => [...values].sort();

test("the exported table covers the constants it claims to export", () => {
  assert.equal(table.commandPrefix, COMMAND_PREFIX);
  assert.equal(table.maxSignalPayloadCharacters, MAX_SIGNAL_PAYLOAD_CHARACTERS);
  assert.deepEqual(sorted(Object.keys(table.services)), sorted(SERVICE_IDS));
});

test("every service in the fixture is the live routing table", () => {
  for (const id of SERVICE_IDS) {
    const live = ROUTES[id];
    const exported = table.services[id];
    assert.ok(exported !== undefined, `${id}: missing from the fixture`);
    assert.deepEqual(exported.canonical, sorted(live.canonical), `${id}: canonical list drifted`);
    assert.deepEqual(exported.denied, sorted(live.denied), `${id}: denied list drifted`);

    const expectedKeys = sorted([...live.canonical, ...live.denied]);
    assert.deepEqual(sorted(Object.keys(exported.actions)), expectedKeys, `${id}: action keys drifted`);
    for (const key of expectedKeys) {
      const spellings = new Set<string>([key]);
      for (const [alias, canonical] of Object.entries(live.aliases)) {
        if (canonical === key) spellings.add(alias);
      }
      assert.deepEqual(
        exported.actions[key],
        sorted(spellings),
        `${id}: ${key} no longer accepts the spellings the fixture lists`
      );
    }

    // Nothing may vanish in the transform: every alias the bridge resolves must appear in some group.
    const exportedSpellings = new Set<string>();
    for (const spellings of Object.values(exported.actions)) for (const spelling of spellings) exportedSpellings.add(spelling);
    for (const alias of Object.keys(live.aliases)) {
      assert.ok(exportedSpellings.has(alias), `${id}: alias ${alias} dropped from the fixture`);
    }
  }
});

test("the offered column of the fixture matches what a plugin actually sees", () => {
  const expected = listServices()
    .map((entry) => ({ id: entry.id, actions: sorted(entry.actions), denied: sorted(entry.denied) }))
    .sort((a, b) => (a.id < b.id ? -1 : 1));
  const actual = [...table.offered].sort((a, b) => (a.id < b.id ? -1 : 1));
  assert.deepEqual(actual, expected, "the offered list drifted from listServices()");
  for (const entry of actual) {
    for (const denied of entry.denied) {
      assert.ok(!entry.actions.includes(denied), `${entry.id}: ${denied} is both offered and denied`);
    }
  }
});

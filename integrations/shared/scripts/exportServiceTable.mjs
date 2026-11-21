/**
 * Regenerates `test/fixtures/service-table.json` from the routing table the bridge actually uses.
 *
 * The fixture exists so that `IntegrationsContractTests` in Swift can grade `ROUTES` against the
 * node's own `dispatch` without re-parsing TypeScript. It is a *derived* artifact: the drift gate is
 * `test/serviceTable.test.ts`, which compares the committed file with the live table, so editing
 * `src/wireCommand.ts` without running this script fails `npm test`.
 *
 *     npm run build && npm run export:table
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  COMMAND_PREFIX,
  MAX_SIGNAL_PAYLOAD_CHARACTERS,
  ROUTES,
  SERVICE_IDS,
  listServices
} from "../dist/src/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const outPath = join(here, "..", "test", "fixtures", "service-table.json");

/** `Object.groupBy` needs Node 21; this package supports 20.10, so group by hand. */
function spellingsByCanonical(serviceId) {
  const table = ROUTES[serviceId];
  const groups = new Map();
  for (const canonical of table.canonical) groups.set(canonical, [canonical]);
  for (const canonical of table.denied) {
    if (!groups.has(canonical)) groups.set(canonical, [canonical]);
  }
  for (const [spelling, canonical] of Object.entries(table.aliases)) {
    const group = groups.get(canonical);
    if (group === undefined) {
      throw new Error(`${serviceId}: alias ${spelling} resolves to ${canonical}, which is not offered`);
    }
    if (!group.includes(spelling)) group.push(spelling);
  }
  const seen = new Set();
  for (const group of groups.values()) for (const spelling of group) seen.add(spelling);
  for (const spelling of Object.keys(table.aliases)) {
    if (!seen.has(spelling)) throw new Error(`${serviceId}: alias ${spelling} dropped from the export`);
  }
  return groups;
}

const services = {};
for (const serviceId of SERVICE_IDS) {
  const table = ROUTES[serviceId];
  const groups = spellingsByCanonical(serviceId);
  const blocked = new Set(table.denied);
  services[serviceId] = {
    canonical: [...table.canonical].sort(),
    denied: [...blocked].sort(),
    // Every spelling the bridge accepts for that canonical action, the canonical name included. The
    // node additionally routes the empty action, which the bridge refuses, so a consumer comparing
    // the two must subtract `""` from its own case list.
    actions: Object.fromEntries(
      [...groups.entries()]
        .sort(([a], [b]) => (a < b ? -1 : 1))
        .map(([canonical, spellings]) => [canonical, [...spellings].sort()])
    )
  };
}

const document = {
  source:
    "GENERATED — do not hand-edit. Run `npm run build && npm run export:table` in integrations/shared. " +
    "Mirrors the dispatch switch in Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2151-2328.",
  commandPrefix: COMMAND_PREFIX,
  maxSignalPayloadCharacters: MAX_SIGNAL_PAYLOAD_CHARACTERS,
  services,
  // `listServices()` is what a plugin sees; keeping its shape here lets the Swift gate assert that the
  // offering and the routing table cannot disagree about which names are denied.
  offered: listServices().map((entry) => ({
    id: entry.id,
    actions: [...entry.actions].sort(),
    denied: [...entry.denied].sort()
  }))
};

const json = `${JSON.stringify(document, null, 2)}\n`;
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, json, "utf8");
console.log(`wrote ${outPath} (${json.length} bytes, ${SERVICE_IDS.length} services)`);

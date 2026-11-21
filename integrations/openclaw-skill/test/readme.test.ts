/**
 * The two READMEs are one document in two languages, so a Swift contract test can compare their
 * structure. This is that check, runnable here: headings, tables, links, the exact set of facts
 * (service ids, action names, ports, `file:line` citations) and the fenced blocks byte for byte.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { ROUTES, SERVICE_IDS, type ServiceId } from "@popopx/node-bridge";

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
const REPO_ROOT = join(ROOT, "..", "..");
const ENGLISH = join(ROOT, "README.md");
const CHINESE = join(ROOT, "README.zh-CN.md");

/** A Han ideograph, in either the CJK Unified or the Extension A block. */
const HAN = /[\u3400-\u4dbf\u4e00-\u9fff]/;

/** Every action name the kernel knows, canonical or alias, empty spelling excluded. */
const ACTION_UNIVERSE = new Set<string>(
  SERVICE_IDS.flatMap((id) =>
    [...Object.keys(ROUTES[id].aliases), ...ROUTES[id].canonical].filter((name) => name !== "")
  )
);

interface Probe {
  readonly levelTwo: number;
  readonly levelThree: number;
  readonly tableRows: number;
  readonly fences: readonly string[];
  readonly links: readonly string[];
  readonly citations: readonly string[];
  readonly services: readonly string[];
  readonly actions: readonly string[];
  readonly tools: readonly string[];
  readonly ports: readonly string[];
  readonly hanLines: number;
  readonly hanCharacters: number;
}

function probe(text: string): Probe {
  const fences: string[][] = [];
  let current: string[] | null = null;
  let levelTwo = 0;
  let levelThree = 0;
  let tableRows = 0;
  let hanLines = 0;
  for (const line of text.split("\n")) {
    const marker = /^```(\S*)\s*$/.exec(line);
    if (marker !== null) {
      if (current === null) current = [marker[1] ?? ""];
      else {
        fences.push(current);
        current = null;
      }
      continue;
    }
    if (current !== null) {
      current.push(line);
      continue;
    }
    if (/^## \S/.test(line)) levelTwo += 1;
    if (/^### \S/.test(line)) levelThree += 1;
    if (/^\|/.test(line)) tableRows += 1;
    if (HAN.test(line)) hanLines += 1;
  }
  assert.equal(current, null, "an unterminated fence would make every count below meaningless");

  const spans = [...text.matchAll(/`([^`\n]+)`/g)].map((match) => match[1] ?? "");
  const citations = [...text.matchAll(/(?:Sources|integrations)\/[\w./-]+\.(?:swift|ts|md):\d+(?:-\d+)?/g)].map(
    (match) => match[0]
  );
  const links = [...text.matchAll(/\]\(([^)\s]+)\)/g)].map((match) => match[1] ?? "");
  const ports = new Set<string>([
    ...[...text.matchAll(/https?:\/\/[\w.-]+:(\d{4,5})/g)].map((match) => match[1] ?? ""),
    ...[...text.matchAll(/(?:127\.0\.0\.1|localhost):(\d{4,5})\b/g)].map((match) => match[1] ?? "")
  ]);
  const tools = new Set<string>(
    [...text.matchAll(/\bpopopx_([a-z_]+)\b/g)]
      .map((match) => match[1] ?? "")
      .filter((id): id is ServiceId => (SERVICE_IDS as readonly string[]).includes(id))
  );

  return {
    levelTwo,
    levelThree,
    tableRows,
    // Each fence becomes one string: the language tag, a newline, then the exact body.
    fences: fences.map((fence) => `${fence[0]}\n${fence.slice(1).join("\n")}`),
    // The cross-language link is the one line the two files are meant to differ on.
    links: [...new Set(links)].filter((target) => target !== "README.md" && target !== "README.zh-CN.md").sort(),
    citations: [...new Set(citations)].sort(),
    services: SERVICE_IDS.filter((id) => text.includes(id)),
    actions: [...new Set(spans.filter((span) => ACTION_UNIVERSE.has(span)))].sort(),
    tools: [...tools].sort(),
    ports: [...ports].sort(),
    hanLines,
    hanCharacters: [...text].filter((character) => HAN.test(character)).length
  };
}

const english = readFileSync(ENGLISH, "utf8");
const chinese = readFileSync(CHINESE, "utf8");
const en = probe(english);
const zh = probe(chinese);

test("both languages carry the same document shape", () => {
  assert.ok(en.levelTwo >= 8, "these are real sections, not a stub");
  assert.equal(zh.levelTwo, en.levelTwo, "the count of `## ` headings must match");
  assert.equal(zh.levelThree, en.levelThree);
  assert.equal(zh.tableRows, en.tableRows, "the tables must have the same number of rows");
  assert.equal(zh.fences.length, en.fences.length, "the same number of fenced blocks");
  assert.ok(en.fences.length >= 10, "the commands, the grammar and the manual check all live in fences");
});

test("every fenced block is byte-identical across the two languages", () => {
  // Commands, wire lines and the manual-check script are language-neutral by design: what can be
  // pasted into one README can be pasted into the other, so a translation cannot invent a flag.
  zh.fences.forEach((fence, index) => {
    assert.equal(fence, en.fences[index], `fence ${index + 1} drifted from the English original`);
    const body = fence.split("\n").slice(1).join("\n");
    assert.ok(
      body.split("\n").every((line) => !/[^\x00-\x7f]/.test(line)),
      `fence ${index + 1} is not ASCII, so it cannot be identical in both languages`
    );
  });
});

test("the two READMEs state the same set of protocol facts", () => {
  // Both sides sorted: SERVICE_IDS is in engine-declaration order, not alphabetical.
  const all = [...SERVICE_IDS].sort();
  assert.deepEqual([...en.services].sort(), all, "all ten services must be named in English");
  assert.deepEqual([...zh.services].sort(), all, "and in Chinese");
  assert.deepEqual([...en.tools].sort(), all, "every tool name, once per service");
  assert.deepEqual([...zh.tools].sort(), all, "and the same set of tool names in Chinese");
  assert.deepEqual(zh.citations, en.citations);
  assert.deepEqual(zh.actions, en.actions);
  assert.deepEqual(zh.ports, en.ports);
  assert.deepEqual(en.ports, ["18920"], "one port, and both READMEs say so");
  assert.deepEqual(zh.links, en.links);
});

test("the action table covers every action the kernel will route", () => {
  const documented = new Set(en.actions);
  for (const id of SERVICE_IDS) {
    for (const action of ROUTES[id].canonical) {
      if (ROUTES[id].denied.includes(action)) continue;
      assert.ok(documented.has(action), `${id} ${action} is missing from the README action table`);
    }
  }
  for (const action of ROUTES.phantom_sentinel.denied) {
    assert.ok(documented.has(action), `the denied ${action} must be named, not hidden`);
  }
});

test("the citations point at lines that really are there", () => {
  for (const citation of en.citations) {
    const [path, range] = citation.split(":");
    assert.ok(path !== undefined && range !== undefined, `${citation} is not a file:line reference`);
    const file = join(REPO_ROOT, path);
    assert.ok(existsSync(file), `${citation} names a file that is not in the repository`);
    if (!path.startsWith("Sources/")) continue;
    const lines = readFileSync(file, "utf8").split("\n");
    const bounds = range.split("-").map((part) => Number(part));
    const from = bounds[0] ?? 0;
    const to = bounds[1] ?? bounds[0] ?? 0;
    assert.ok(from >= 1 && to >= from && to <= lines.length, `${citation} runs outside ${path}`);
    const window = lines.slice(from - 1, to).join("\n");
    if (path.endsWith("MacNodeModels.swift")) {
      assert.match(window, /NODE_CMD/, `${citation} is not the parser it claims to be`);
      assert.match(window, /maxSignalPayloadCharacters/, `${citation} is not the budget it claims to be`);
      assert.match(window, /components\(separatedBy: "::"\)/, `${citation} is not the split it claims to be`);
    }
    if (path.endsWith("TenBusinessEngines.swift") && to - from > 4) {
      assert.match(window, /func dispatch|case ""|lockdown/, `${citation} is not the dispatch it claims to be`);
    }
  }
  assert.ok(
    en.citations.some((citation) => citation.endsWith("MacNodeModels.swift:106-139")),
    "the grammar must be cited to the Swift parser"
  );
  assert.ok(
    en.citations.some((citation) => citation.endsWith("TenBusinessEngines.swift:2199-2328")),
    "the ten services must be cited to the Swift dispatch"
  );
  const lockdownLines = en.citations.filter((citation) => citation.includes("TenBusinessEngines.swift"));
  assert.ok(lockdownLines.length >= 6, "each destructive effect needs its own line citation");
});

test("links go somewhere, and the cross-reference points at the other language", () => {
  for (const target of en.links) {
    assert.ok(!target.startsWith("http"), `a README should not depend on a web URL: ${target}`);
    assert.ok(existsSync(join(ROOT, target)), `the READMEs link to ${target}, which is not there`);
  }
  assert.ok(english.includes("(README.zh-CN.md)"), "the English file must offer the Chinese one");
  assert.ok(chinese.includes("(README.md)"), "and the Chinese file must offer the English one");
});

test("the English file is English, the Chinese file is Chinese", () => {
  assert.equal(en.hanLines, 0, "README.md may not contain Han characters: the contract counts them");
  assert.ok(zh.hanLines > 8, `README.zh-CN.md looks untranslated (${zh.hanLines} Han lines)`);
  assert.ok(zh.hanCharacters > 200, "a real translation, not a title in Chinese");
});

test("neither README leaks a path, a token, or an unfinished sentence", () => {
  for (const [path, text] of [
    [ENGLISH, english],
    [CHINESE, chinese]
  ] as const) {
    // The needles are assembled at runtime, because a repo-wide scan for these literals would
    // otherwise fail on the guard that forbids them.
    assert.ok(!text.includes(["/Us", "ers/"].join("")), `${path} must not name a developer home`);
    const unfinished = new RegExp(`\\b${["TO", "DO"].join("")}\\b|\\b${["FIX", "ME"].join("")}\\b`);
    assert.ok(!unfinished.test(text), `${path} is not finished`);
    assert.ok(!text.includes("…"), `${path} uses an ellipsis instead of a real sentence`);
    assert.ok(!/ws:\/\//.test(text), `there is no WebSocket on the console port, and ${path} must not imply one`);
    assert.ok(!/\?t=[A-Za-z0-9]{8,}/.test(text), `${path} must not carry a token`);
    assert.ok(!/[A-Za-z0-9]{32,}/.test(text), `${path} contains something that looks like a secret`);
    assert.ok(!/simplex/i.test(text), `${path} names the wrong product`);
  }
});

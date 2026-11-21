/**
 * Deployment tests: the installer's syntax, its templates, and the two refusals that must happen
 * before a single byte is written. Everything runs against a throwaway `HOME` and a stub bridge
 * directory, so no LaunchAgent or systemd unit of the real operator is touched and nothing is
 * loaded - `--render-only` keeps `launchctl` and `systemctl` out of the picture entirely.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const TOKEN = "ZqDeployTestToken0123456789ab";

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
const DEPLOY = join(ROOT, "deploy");
const INSTALL = join(DEPLOY, "install.sh");
const PLIST_TEMPLATE = join(DEPLOY, "launchd.com.popopx.bridge.plist.template");
const UNIT_TEMPLATE = join(DEPLOY, "popopx-bridge@.service.template");
const PLIST_NAME = "com.popopx.bridge.plist";

interface Run {
  readonly status: number;
  readonly out: string;
  readonly err: string;
}

function runInstaller(args: readonly string[], env: Readonly<Record<string, string | undefined>>): Run {
  const result = spawnSync("sh", [INSTALL, ...args], {
    encoding: "utf8",
    cwd: ROOT,
    env: {
      // A narrow environment: the test must not inherit an operator's real handoff or opt-in.
      PATH: "/bin:/usr/bin:/usr/local/bin",
      HOME: env["HOME"],
      PPX_CONSOLE_TOKEN: env["PPX_CONSOLE_TOKEN"],
      ...(env["PPX_ALLOW_LOCKDOWN"] === undefined ? {} : { PPX_ALLOW_LOCKDOWN: env["PPX_ALLOW_LOCKDOWN"] })
    }
  });
  return { status: result.status ?? -1, out: result.stdout ?? "", err: result.stderr ?? "" };
}

function tree(root: string): readonly string[] {
  const found: string[] = [];
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else found.push(relative(root, path));
    }
  };
  if (existsSync(root)) walk(root);
  return found.sort();
}

/** A bridge directory is only required to hold the entry point the unit will call. */
function stubBridgeDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "ppx-bridge-"));
  mkdirSync(join(dir, "dist", "src"), { recursive: true });
  writeFileSync(join(dir, "dist", "src", "index.js"), "export const plugin = { meta: {}, register: () => {} };\n");
  return dir;
}

function scratchHome(): string {
  return mkdtempSync(join(tmpdir(), "ppx-home-"));
}

const PLIST_PATH = (home: string): string => join(home, "Library", "LaunchAgents", PLIST_NAME);
const UNIT_PATH = (home: string, instance: string): string =>
  join(home, ".config", "systemd", "user", `popopx-bridge@${instance}.service`);

test("the installer parses as POSIX sh, with no bash-only syntax", () => {
  const syntax = spawnSync("sh", ["-n", INSTALL], { encoding: "utf8" });
  assert.equal(syntax.status, 0, syntax.stderr);
  const text = readFileSync(INSTALL, "utf8");
  assert.match(text, /^set -eu$/m, "the script runs with errexit and nounset");
  // A guard on the word alone would fire on the script's own prose, so it matches sudo in command
  // position only: line start, after an assignment prefix, before a flag or an argument.
  const inCommandPosition = text
    .split("\n")
    .some((line) => /^\s*(?:\w+=\S*\s+)*sudo(\s|$)/.test(line) || /[;&|]\s*sudo(\s|$)/.test(line));
  assert.ok(!inCommandPosition, "nothing here may need sudo");
  assert.ok(!/\bcurl\b|\bwget\b/.test(text), "the installer fetches nothing, so nothing is piped to a shell");
  assert.ok(!/\blocal\b\s+\w/.test(text), "no `local`, which is not POSIX sh");
  assert.match(text, /launchctl print/, "it verifies instead of assuming");
  assert.match(text, /systemctl --user status/, "and verifies on systemd too");
});

test("the committed templates carry placeholders, not a developer's paths", () => {
  for (const path of [PLIST_TEMPLATE, UNIT_TEMPLATE]) {
    const text = readFileSync(path, "utf8");
    assert.ok(!text.includes(["/Us", "ers/"].join("")), `${path} must not name a macOS home`);
    assert.ok(!text.includes(["/ho", "me/"].join("")), `${path} must not name a Linux home`);
    assert.ok(!text.includes(TOKEN), "a template is a committed file");
    assert.ok(!/"token"\s*:/.test(text), "no template may carry an inline token");
    assert.match(text, /127\.0\.0\.1:18920/, "the one port is the only endpoint");
    assert.ok(!text.includes(["w", "s://"].join("")), "there is no WebSocket on the console port");
  }
  const plist = readFileSync(PLIST_TEMPLATE, "utf8");
  assert.ok(plist.includes("@BRIDGE_DIR@"), "the plist template takes the install location from @BRIDGE_DIR@");
  assert.ok(plist.includes("@OPENCLAW_BIN@"));
  assert.ok(plist.includes("@ALLOW_LOCKDOWN@"));
  const unit = readFileSync(UNIT_TEMPLATE, "utf8");
  assert.ok(unit.includes("${BRIDGE_DIR}"), "the unit template takes it from ${BRIDGE_DIR}");
  assert.ok(unit.includes("${OPENCLAW_BIN}"));
  assert.ok(unit.includes("${ALLOW_LOCKDOWN}"));
  assert.ok(unit.includes("%i"), "the instance name stays a real systemd specifier");
});

test("no token, no install", () => {
  const home = scratchHome();
  const bridge = stubBridgeDir();
  try {
    const run = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--launchd"], { HOME: home });
    assert.notEqual(run.status, 0);
    assert.match(run.err, /PPX_CONSOLE_TOKEN/);
    assert.deepEqual(tree(home), [], "a refused install must not create anything");
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("the rendered unit never carries the token, in its body or in the installer's own output", () => {
  const home = scratchHome();
  const bridge = stubBridgeDir();
  try {
    const run = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.equal(run.status, 0, run.err);
    assert.ok(!run.out.includes(TOKEN) && !run.err.includes(TOKEN), "the installer does not echo the secret");
    const rendered = readFileSync(PLIST_PATH(home), "utf8");
    assert.ok(!rendered.includes(TOKEN));
    assert.ok(rendered.includes(bridge), "the install location was substituted");
    assert.ok(rendered.includes("/bin/sh"));
    assert.ok(!rendered.includes("@BRIDGE_DIR@") && !rendered.includes("@OPENCLAW_BIN@"));
    assert.equal(statSync(PLIST_PATH(home)).mode & 0o777, 0o600, "owner-only, like every other bridge artifact");
    const lint = spawnSync("plutil", ["-lint", PLIST_PATH(home)], { encoding: "utf8" });
    if (lint.status !== -1) assert.equal(lint.status, 0, lint.stdout + lint.stderr);
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("the systemd render carries the entry point, the instance and a refused lockdown path", () => {
  const home = scratchHome();
  const bridge = stubBridgeDir();
  try {
    const run = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--systemd", "--instance", "lab"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.equal(run.status, 0, run.err);
    const rendered = readFileSync(UNIT_PATH(home, "lab"), "utf8");
    assert.ok(!rendered.includes(TOKEN));
    assert.ok(rendered.includes(`ExecStart=/bin/sh --plugin ${bridge}/dist/src/index.js`), rendered);
    assert.ok(rendered.includes("Environment=PPX_ALLOW_LOCKDOWN=0"));
    assert.ok(rendered.includes("popopx-bridge@") === false, "the instance is in the file name, systemd fills %i");
    assert.ok(rendered.includes("Description=POPOPX Mac Node bridge, OpenClaw skill (instance %i)"));
    assert.ok(!rendered.includes("${BRIDGE_DIR}") && !rendered.includes("${OPENCLAW_BIN}"));
    assert.ok(!run.out.includes(TOKEN));
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("installing with the lockdown path granted is refused, and nothing is written", () => {
  const home = scratchHome();
  const bridge = stubBridgeDir();
  try {
    for (const flag of ["1", "true", "yes"]) {
      const run = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--launchd"], {
        HOME: home,
        PPX_CONSOLE_TOKEN: TOKEN,
        PPX_ALLOW_LOCKDOWN: flag
      });
      assert.notEqual(run.status, 0, `PPX_ALLOW_LOCKDOWN=${flag} must be refused`);
      assert.match(run.err, /lockdown/);
      assert.match(run.err, /CONTRACT\.md section 7/);
    }
    assert.deepEqual(tree(home), [], "the refusal comes before any write");
    const bogus = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN,
      PPX_ALLOW_LOCKDOWN: "maybe"
    });
    assert.notEqual(bogus.status, 0);
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("both targets render into the user's own directories and nowhere else", () => {
  const home = scratchHome();
  const bridge = stubBridgeDir();
  try {
    const run = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--target", "both"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.equal(run.status, 0, run.err);
    assert.deepEqual(tree(home), [
      join(".config", "systemd", "user", "popopx-bridge@default.service"),
      join("Library", "LaunchAgents", PLIST_NAME)
    ]);
    assert.equal(tree(home).length, 2, "exactly two files, one per backend");
    assert.ok(existsSync(join(bridge, "logs")), "the log directory the units write into is created");
    assert.deepEqual(tree(bridge), [join("dist", "src", "index.js")], "the log directory holds no files");
    assert.match(run.out, /rendered: /);
    assert.ok(!run.out.includes(TOKEN));
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("rendering twice changes nothing, and a changed host is picked up", () => {
  const home = scratchHome();
  const bridge = stubBridgeDir();
  try {
    const first = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.equal(first.status, 0, first.err);
    assert.match(first.out, /rendered:/);
    const bytes = readFileSync(PLIST_PATH(home), "utf8");

    const again = runInstaller([bridge, "--render-only", "--host", "/bin/sh", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.equal(again.status, 0, again.err);
    assert.match(again.out, /unchanged:/, "the installer is idempotent, so an operator can re-run it");
    assert.equal(readFileSync(PLIST_PATH(home), "utf8"), bytes);

    const moved = runInstaller([bridge, "--render-only", "--host", "/bin/cat", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.equal(moved.status, 0, moved.err);
    assert.match(moved.out, /rendered:/);
    assert.ok(readFileSync(PLIST_PATH(home), "utf8").includes("/bin/cat"));
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("the installer refuses a build it cannot point at, and a host it cannot run", () => {
  const home = scratchHome();
  const empty = mkdtempSync(join(tmpdir(), "ppx-empty-"));
  const bridge = stubBridgeDir();
  try {
    const noBuild = runInstaller([empty, "--render-only", "--host", "/bin/sh", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.notEqual(noBuild.status, 0);
    assert.match(noBuild.err, /npm run build/);

    // A build the installer can point at, so the host checks below are the ones that fail.
    const relativeHost = runInstaller([bridge, "--render-only", "--host", "openclaw", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.notEqual(relativeHost.status, 0);
    assert.match(relativeHost.err, /absolute path/);

    const missingHost = runInstaller([bridge, "--render-only", "--host", "/definitely/not/here", "--launchd"], {
      HOME: home,
      PPX_CONSOLE_TOKEN: TOKEN
    });
    assert.notEqual(missingHost.status, 0);
    assert.match(missingHost.err, /not runnable/);
    assert.deepEqual(tree(home), []);
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(empty, { recursive: true, force: true });
    rmSync(bridge, { recursive: true, force: true });
  }
});

test("--help explains the flags an operator needs, without touching the system", () => {
  const run = runInstaller(["--help"], { HOME: undefined, PPX_CONSOLE_TOKEN: undefined });
  assert.equal(run.status, 0, run.err);
  assert.match(run.out, /--render-only/);
  assert.match(run.out, /--target auto\|launchd\|systemd\|both/);
  assert.match(run.out, /Library\/LaunchAgents/);
  assert.match(run.out, /\.config\/systemd\/user/);
  assert.match(run.out, /PPX_CONSOLE_TOKEN/);
  assert.match(run.out, /never uses sudo|--host PATH/);
  assert.ok(!run.out.includes(TOKEN));
  assert.ok(!/\/Users\/|\/home\/[a-z0-9._-]+\//.test(run.out), "help prints no developer-machine home");
});

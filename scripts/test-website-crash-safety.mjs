#!/usr/bin/env node
// Regression test for a real incident: `spawn("cloudflared", ...)` in
// plugins/website/index.ts threw `Error: spawn cloudflared ENOENT` as an
// unhandled 'error' event on the ChildProcess, which is fatal to the whole
// Node gateway process by default (not just the one request that triggered
// it). Docker's `restart: unless-stopped` then silently relaunched the
// entire container, so the visible customer-facing symptom was "the bot
// got stuck," not an obvious crash.
//
// This script proves plugins/website/index.ts (the real, shipped file --
// copied byte-for-byte into a throwaway dir below, diffed first) survives
// that failure mode and reports a clean per-request error instead. Run it
// with:
//   node scripts/test-website-crash-safety.mjs
//
// Exits 0 and prints "ALL SCENARIOS PASSED" if the fix holds, exits 1 and
// prints exactly what broke otherwise (an uncaughtException/unhandledRejection
// firing anywhere here is exactly the crash this guards against).

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const sourceFile = path.join(repoRoot, "plugins", "website", "index.ts");

const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "website-crash-test-"));
process.on("exit", () => {
  fs.rmSync(workDir, { recursive: true, force: true });
});

// Stub out the "openclaw/plugin-sdk/plugin-entry" import the real plugin
// file needs -- definePluginEntry is just identity for our purposes, we
// only need `.register(api)` to be callable on the default export.
const openclawPkgDir = path.join(workDir, "node_modules", "openclaw");
fs.mkdirSync(path.join(openclawPkgDir, "plugin-sdk"), { recursive: true });
fs.writeFileSync(
  path.join(openclawPkgDir, "package.json"),
  JSON.stringify(
    {
      name: "openclaw",
      version: "0.0.0",
      type: "module",
      exports: { "./plugin-sdk/plugin-entry": "./plugin-sdk/plugin-entry.mjs" },
    },
    null,
    2,
  ),
);
fs.writeFileSync(
  path.join(openclawPkgDir, "plugin-sdk", "plugin-entry.mjs"),
  "export function definePluginEntry(x) { return x; }\n",
);

const pluginCopyPath = path.join(workDir, "plugin.mjs");
fs.copyFileSync(sourceFile, pluginCopyPath);
const diff = fs.readFileSync(sourceFile, "utf8") === fs.readFileSync(pluginCopyPath, "utf8");
if (!diff) {
  console.error("FAIL: copy of plugins/website/index.ts is not byte-identical to the source -- aborting.");
  process.exit(1);
}
console.log(`Testing real, unmodified source: ${path.relative(repoRoot, sourceFile)} (byte-identical copy confirmed)`);

let crashed = false;
let crashReason = null;
process.on("uncaughtException", (err) => {
  crashed = true;
  crashReason = `uncaughtException: ${err && err.stack ? err.stack : err}`;
});
process.on("unhandledRejection", (err) => {
  crashed = true;
  crashReason = `unhandledRejection: ${err && err.stack ? err.stack : err}`;
});

function makeFakeApi() {
  const tools = {};
  const api = {
    runtime: { llm: { complete: async () => ({ text: "<html></html>" }) } },
    on() {},
    registerTool(def) {
      tools[def.name] = def;
    },
    registerCommand() {},
  };
  return { api, tools };
}

async function runScenario(label, { patchExistsSync }) {
  console.log(`\n=== Scenario: ${label} ===`);
  const originalExistsSync = fs.existsSync;
  if (patchExistsSync) {
    // Same shared node:fs module object the plugin itself imports --
    // mutating a method here is visible to it too. Lets the pre-check pass
    // so the real spawn("/data/bin/cloudflared", ...) call underneath runs
    // for real and hits a genuine ENOENT (this host has no such binary),
    // exercising the actual proc.on("error", ...) handling -- the real fix
    // for the incident -- rather than only the shallower existence check.
    fs.existsSync = (p) => (p === "/data/bin/cloudflared" ? true : originalExistsSync(p));
  }

  const mod = await import(`${pluginCopyPath}?scenario=${encodeURIComponent(label)}`);
  const plugin = mod.default;
  const { api, tools } = makeFakeApi();
  plugin.register(api);

  const publishTool = tools.publish_website;
  if (!publishTool) throw new Error("publish_website tool was not registered");

  const start = Date.now();
  const result = await publishTool.execute("test-tool-call-1", {
    html: "<html><body>hi</body></html>",
    title: "test",
  });
  const elapsedMs = Date.now() - start;

  fs.existsSync = originalExistsSync;

  console.log("tool result:", JSON.stringify(result));
  console.log(`elapsed: ${elapsedMs}ms`);

  const text = result?.content?.[0]?.text ?? "";
  const cleanlyReported = typeof text === "string" && /Couldn't publish that page/.test(text);
  if (!cleanlyReported) {
    throw new Error(`Expected a clean "Couldn't publish that page: ..." error, got: ${JSON.stringify(result)}`);
  }
  console.log(`PASS: ${label}`);
}

try {
  await runScenario("A: fs.existsSync pre-check fails (real state on this host, no mocking)", {
    patchExistsSync: false,
  });
  await runScenario("B: pre-check passes, real spawn() ENOENT ('error' event path)", {
    patchExistsSync: true,
  });
} catch (err) {
  console.error("\nTEST FAILED:", err);
  process.exitCode = 1;
}

// Give any stray async 'error'/rejection a tick to surface before deciding
// the process is still alive and uncorrupted.
await new Promise((r) => setTimeout(r, 250));

if (crashed) {
  console.error(`\nFAIL: process-level crash signal observed: ${crashReason}`);
  process.exitCode = 1;
} else if (process.exitCode !== 1) {
  console.log(
    "\nALL SCENARIOS PASSED -- process survived both a missing cloudflared binary and a real spawn() ENOENT, both requests got a clean reported error, no uncaughtException/unhandledRejection fired.",
  );
}

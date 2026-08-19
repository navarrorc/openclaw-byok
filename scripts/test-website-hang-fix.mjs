#!/usr/bin/env node
// Regression test for the 08-19 live hang incident: a real /website
// follow-up request got stuck with NO resolution at all -- not even the
// thinking-bubble 3-minute stuck-placeholder safety net cleared it. Root
// cause: `tg()`'s `fetch()` call to the Telegram Bot API had no timeout, so
// a stalled connection (confirmed live on the deployed box: a `fetch()`
// with no signal against a socket that accepts but never responds was
// still pending 15+ seconds later) could hang the reply_dispatch handler
// forever with no error ever surfacing. A second, independent bug in the
// same incident: the thinking-bubble placeholder was settled (removed from
// tracking) BEFORE the hanging send, not after, so the 3-minute safety net
// had nothing left to sweep even though the user never got a reply.
//
// This proves, against the real, unmodified plugins/website/index.ts (byte
// -identical copy checked, same as scripts/test-website-crash-safety.mjs):
//   1. A stalled Telegram API call no longer hangs the reply_dispatch
//      handler indefinitely -- it now settles within a bounded time.
//   2. The thinking-bubble settle callback is NOT invoked when delivery
//      never succeeds (even the error notice), so the 3-minute safety net
//      is left as the true last resort instead of being defeated early.
//
// Run with: node scripts/test-website-hang-fix.mjs

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import http from "node:http";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const sourceFile = path.join(repoRoot, "plugins", "website", "index.ts");

const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "website-hang-fix-test-"));
process.on("exit", () => {
  fs.rmSync(workDir, { recursive: true, force: true });
});

const openclawPkgDir = path.join(workDir, "node_modules", "openclaw");
fs.mkdirSync(path.join(openclawPkgDir, "plugin-sdk"), { recursive: true });
fs.writeFileSync(
  path.join(openclawPkgDir, "package.json"),
  JSON.stringify(
    { name: "openclaw", version: "0.0.0", type: "module", exports: { "./plugin-sdk/plugin-entry": "./plugin-sdk/plugin-entry.mjs" } },
    null,
    2,
  ),
);
fs.writeFileSync(path.join(openclawPkgDir, "plugin-sdk", "plugin-entry.mjs"), "export function definePluginEntry(x) { return x; }\n");

const pluginCopyPath = path.join(workDir, "plugin.mjs");
fs.copyFileSync(sourceFile, pluginCopyPath);
if (fs.readFileSync(sourceFile, "utf8") !== fs.readFileSync(pluginCopyPath, "utf8")) {
  console.error("FAIL: copy of plugins/website/index.ts is not byte-identical to the source -- aborting.");
  process.exit(1);
}
console.log(`Testing real, unmodified source: ${path.relative(repoRoot, sourceFile)} (byte-identical copy confirmed)`);

// A server that accepts the TCP connection but never writes a response --
// the exact real-world condition confirmed live on the deployed box to hang
// an unguarded fetch() well past 15 seconds (undici's own default is 300s).
const stallServer = http.createServer(() => {
  // never respond
});
await new Promise((resolve) => stallServer.listen(0, "127.0.0.1", resolve));
const stallPort = stallServer.address().port;

// Redirect tg()'s hardcoded api.telegram.org URL to the stalling server
// while still passing through the real `signal` option -- this exercises
// the real AbortSignal.timeout() wiring in the shipped tg() unchanged.
const realFetch = globalThis.fetch;
globalThis.fetch = (_url, opts) => realFetch(`http://127.0.0.1:${stallPort}/`, opts);

process.env.WEBSITE_BOT_TOKEN = "fake-test-token";

// Fake settler -- proves whether website's reply_dispatch handler considers
// this session "resolved" (must NOT happen when delivery never succeeds).
let settlerCalls = 0;
globalThis[Symbol.for("openclaw-byok.thinking-bubble.getReplyDispatchSettler")] = () => {
  return () => {
    settlerCalls += 1;
  };
};

const mod = await import(pluginCopyPath);
const plugin = mod.default;

const hooks = {};
const commands = {};
const api = {
  runtime: { llm: { complete: async () => ({ text: "<html><body>hi</body></html>" }) } },
  on(name, handler) {
    (hooks[name] ??= []).push(handler);
  },
  registerTool() {},
  registerCommand(def) {
    commands[def.name] = def;
  },
};
plugin.register(api);

// Prime the "awaiting description" state the same way a real bare
// `/website` does, so the reply_dispatch handler below actually claims the
// follow-up message instead of ignoring it.
await commands.website.handler({ args: "", sessionKey: "test:session" });

const replyDispatchHandler = hooks.reply_dispatch[0];
const dispatchCtx = {
  onReplyStart: async () => {},
  dispatcher: { markComplete() {}, getQueuedCounts: () => ({}) },
  recordProcessed() {},
  markIdle() {},
};
const event = {
  sessionKey: "test:session",
  ctx: {
    BodyForCommands: "a simple test page",
    Provider: "telegram",
    ChatId: "555",
  },
};

let crashed = false;
process.on("uncaughtException", (err) => {
  crashed = true;
  console.error("uncaughtException:", err);
});
process.on("unhandledRejection", (err) => {
  crashed = true;
  console.error("unhandledRejection:", err);
});

console.log("Invoking the real reply_dispatch handler against a stalled Telegram API (never responds)...");
const t0 = Date.now();
// Hard external watchdog -- this test itself must never hang either. Set
// comfortably above TG_FETCH_TIMEOUT_MS + REPLY_DISPATCH_WORK_TIMEOUT_MS
// margins so a genuine regression (a real hang) fails loudly instead of
// just making the test runner itself hang forever.
const watchdog = setTimeout(() => {
  console.error("FAIL: reply_dispatch handler did not settle within 120s -- the hang regressed.");
  process.exit(1);
}, 120_000);
watchdog.unref?.();

await replyDispatchHandler(event, dispatchCtx);
const elapsedMs = Date.now() - t0;
clearTimeout(watchdog);

console.log(`reply_dispatch handler resolved after ${elapsedMs}ms`);
console.log(`thinking-bubble settle callback invoked ${settlerCalls} time(s)`);

let failed = false;
if (elapsedMs > 60_000) {
  console.error(`FAIL: handler took ${elapsedMs}ms against a stalled Telegram API -- expected a bounded failure well under 60s.`);
  failed = true;
} else {
  console.log("PASS: handler resolved in bounded time instead of hanging.");
}

if (settlerCalls !== 0) {
  console.error(
    `FAIL: thinking-bubble settle callback was invoked ${settlerCalls} time(s) even though delivery never succeeded -- this is the exact ordering bug that defeated the 3-minute safety net in the real incident.`,
  );
  failed = true;
} else {
  console.log("PASS: thinking-bubble placeholder was left tracked (not prematurely settled) since delivery never succeeded -- the safety net remains the last resort.");
}

globalThis.fetch = realFetch;
stallServer.close();

await new Promise((r) => setTimeout(r, 250));

if (crashed) {
  console.error("FAIL: process-level crash signal observed during the test.");
  failed = true;
}

if (failed) {
  process.exitCode = 1;
} else {
  console.log("\nALL CHECKS PASSED -- a stalled Telegram API call no longer hangs the reply_dispatch handler, and the thinking-bubble safety net is not prematurely defeated.");
}

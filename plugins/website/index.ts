// Website plugin
//
// Lets the agent publish a self-contained HTML page it just generated (a
// dashboard, a form, a small tool) as a real, live, token-gated website the
// Telegram user can open in a browser, then close when done. The agent does
// its own HTML/CSS/JS generation -- this plugin only publishes it.
//
// Three product-owner decisions this encodes (do not redesign):
//   1. Tunnel: an unbranded Cloudflare Quick Tunnel spun up per session
//      (`cloudflared tunnel --url http://127.0.0.1:<port>`), not a shared
//      relay we operate -- this product's pitch is "we never touch your
//      infrastructure," and routing customer web-UI traffic through
//      infrastructure we control would be in tension with that.
//   2. Teardown is close_website-only. No idle auto-timeout -- explicit
//      on/off, matching this product's support-access.sh philosophy.
//   3. The link is shared as plain text, not a Telegram Web App button --
//      a `web_app` button needs its domain pre-registered with BotFather,
//      which a fresh random *.trycloudflare.com subdomain can never satisfy.
//
// --- cloudflared binary path and crash-proofing (08-18 incident) ---
//
// This crashed a live customer gateway: `spawn("cloudflared", ...)` threw
// `Error: spawn cloudflared ENOENT` as an unhandled 'error' event on the
// ChildProcess, which is fatal for the whole Node process by default (not
// just this one request) -- Docker's `restart: unless-stopped` then quietly
// relaunched the entire container, which is why the visible symptom was
// "the bot got stuck," not an obvious crash log.
//
// Root cause: setup.sh used to `docker cp` cloudflared to
// /usr/local/bin/cloudflared, which lives in the container's writable
// layer, NOT the /data volume. Any `docker compose up -d --force-recreate`
// (done routinely to pick up new .env vars) discards that layer and wipes
// the binary, while this plugin file itself (under
// /data/workspace/.openclaw/extensions/website) survives -- so the plugin
// kept running, found nothing to spawn, and took the gateway down with it.
// Fixed by installing to CLOUDFLARED_PATH below, under /data, so it
// survives recreation the same way the plugin code does.
//
// Regardless of where the binary lives, a spawn failure (missing binary,
// bad permissions, OOM, anything) must never be able to crash the gateway
// again: every ChildProcess this file creates gets a permanent
// `.on("error", ...)` listener (so the EventEmitter always has one, for the
// life of the process, not just during startup) plus a temporary one inside
// waitForTunnelUrl that turns a startup-time spawn failure into a normal
// rejected Promise instead of an unhandled event. See createSite() below.
//
// --- Tool-call identity: the real finding from live testing (08-18) ---
//
// AgentTool.execute has signature (toolCallId, params, signal, onUpdate) --
// confirmed from the shipped .d.ts and live logging -- with NO context
// argument at all. There is no chatId/sessionKey available inside execute()
// itself, unlike message hooks.
//
// The docs' `factory` form (`api.registerTool((ctx) => ({...}))`) DOES get
// an OpenClawPluginToolContext with sessionKey/deliveryContext/etc, but it
// turned out to be a dead end: confirmed live that registering a tool via
// the factory form makes ANY real tool-call by the model fail with
// `LLM request failed. rawError=() => { return
// resolveApplicablePluginRuntimeConfig(...) } could not be cloned.` -- a
// real bug in this OpenClaw version's factory-tool runtime-config plumbing,
// reproduced twice, gone as soon as the same tool is registered as a plain
// object instead. So: plain-object `api.registerTool({...})` only, no
// factory, confirmed working live (EXECUTE fires, tool result returned).
//
// The mechanism that DOES carry identity, confirmed live: the
// `before_tool_call` hook's handler is genuinely two-argument,
// `(event, ctx) => ...` (the shipped .d.ts's generic single-arg
// `InternalHookHandler` type does not describe it -- `PluginHookName`'s
// `before_tool_call` entry is separately typed as
// `(event: PluginHookBeforeToolCallEvent, ctx: PluginHookToolContext) => ...`).
// Live dump of that second `ctx` argument for a real tool call:
//   {"toolName":"...", "agentId":"main", "sessionKey":"agent:main:main",
//    "sessionId":"...", "runId":"...", "trace":{...}, "toolCallId":"..."}
// `ctx.sessionKey` is there and stable -- the same key thinking-bubble
// already correlates Telegram turns through. So: this plugin registers an
// observation-only `before_tool_call` hook that stashes `ctx.sessionKey`
// into a small `Map` keyed by `event.toolCallId`, and each tool's
// `execute(toolCallId, ...)` looks its own sessionKey up (and deletes the
// entry) from that same map. sessionKey is the per-chat correlation key
// here (not a raw Telegram chat id) -- fine for this product's documented
// single-user-per-VPS assumption, and if a call somehow arrives with no
// hook-provided sessionKey, publish/close falls back to one shared "global"
// key, which is still correct for a single-user bot, just less precise.
//
// --- No typebox import ---
//
// The building-plugins.md quickstart imports `Type` from "typebox" for
// `parameters`. Confirmed live that this DOES NOT resolve for a
// workspace-extension plugin: `/data/workspace/.openclaw/extensions/website`
// has no ancestor `node_modules/typebox` (it only lives inside
// `/opt/openclaw/app/node_modules`, which Node's module resolution never
// walks up into from workspace paths) -- load fails with
// `Cannot find module 'typebox'`. Confirmed live too that a plain JSON
// Schema object works identically: TypeBox's own `Type.Object(...)` output,
// inspected directly at runtime, is just a plain object
// (`{type, required, properties}`, no symbols, no special prototype) -- so
// `parameters` here is hand-written JSON Schema, no import needed at all.
//
// --- cloudflared URL format, confirmed live ---
//
// Running the real installed binary inside this exact container prints the
// quick-tunnel URL on stdout/stderr as a line inside a bordered INF box,
// e.g. `https://workshops-briefs-rest-president.trycloudflare.com`. Parsed
// with a plain regex against the accumulated stdout+stderr text rather than
// matching the decorative box border, which is cosmetic and not a stable
// contract.
//
// --- Bare `/website` flow: inbound_claim researched and rejected (08-18) ---
//
// The product ask: bare `/website` should explain itself and wait for the
// next message as input, like Nelita's /editvideo. The docs' own hooks
// table names `inbound_claim` for exactly this ("Claim an inbound message
// before agent routing"), so it was researched first, not guessed at.
//
// Static analysis of the shipped bundle (not just the docs) found the real
// mechanism is much heavier than the one-line doc description implies: the
// ONLY call site that invokes `inbound_claim` (dist/dispatch-*.js, the
// `runInboundClaimForPluginOutcome` branch) is gated on
// `if (pluginOwnedBinding)` -- it only fires for a plugin that already owns
// a `PluginConversationBinding` for that conversation. The generic,
// unscoped claim runner (`runInboundClaim`, first-claim-wins across all
// plugins) exists in the hook runner but has zero callers anywhere in the
// bundle. And winning a binding is itself a heavyweight, interactive flow
// (`ctx.requestConversationBinding()`): the first request for a
// conversation returns `status: "pending"` and sends the OWNER an approval
// card ("plugin X wants to bind this conversation, approve?") unless a
// prior "allow always" was already granted. Confirmed no bundled extension
// in this build uses `inbound_claim` either. So the realistic behavior of
// wiring it up here would be: the very first bare `/website` interrupts the
// user with an unrelated approval prompt before they even get the
// explanation -- worse than the current one-line usage hint, not an
// upgrade. Rejected on that evidence; not registered.
//
// --- Fix (round 2), 08-18: reply_dispatch, not message_received ---
//
// Round 1 used `message_received` to notice the next plain-text message
// after a bare `/website` and independently generate+publish+reply to it.
// That's a pure observer hook -- it could not
// stop the normal agent turn from ALSO seeing that same plain text and
// replying to it conversationally, and this exact tradeoff (disclosed at the
// time) turned out to be the same live-confirmed "stray LLM reply" bug Rob
// hit with quick-menu's `/clearchat` (see that plugin's own header for the
// full incident). Same fix applies here: `reply_dispatch` fires BEFORE
// OpenClaw builds the agent turn (confirmed against this deployed version's
// own `src/auto-reply/reply/dispatch-from-config.ts`, ~2973-3020 -- a
// `handled: true` return there causes an early `return` several lines before
// the code that hands the turn to the agent), so claiming the follow-up
// description there is a structural short-circuit, not a race. Same
// proven call sequence as wizbid/reseller's own commands in ai-farm
// (onReplyStart -> do the work -> dispatcher.markComplete() ->
// recordProcessed('completed') -> markIdle(reason)), documented in
// `~/.claude/projects/-home-lenov-projects-ai-farm/memory/
// feedback_openclaw_plugin_for_fast_dispatch.md`.
//
// No default timeout applies to reply_dispatch handlers in this version
// (confirmed against `src/plugins/hooks.ts`'s
// `DEFAULT_MODIFYING_HOOK_TIMEOUT_MS_BY_HOOK` -- reply_dispatch isn't in that
// table, so `getClaimingHookTimeoutMs` returns undefined and `withHookTimeout`
// is skipped), so the `generateHtml()` LLM call this handler makes is safe to
// run inline here, same as it already was inline in message_received.
//
// Sending the plugin's own reply out-of-band (independent of the normal
// command-reply/`continueAgent` pipeline) requires the same direct-Telegram
// pattern thinking-bubble already proved live, not OpenClaw's internal
// `PluginRuntimeChannel` dispatch helpers (`dispatchReplyWithBufferedBlockDispatcher`
// et al.) -- that surface has no bundled-extension usage example either and
// is a much larger, riskier surface to get right untested than one more
// `fetch()` call to the Bot API. Needs its own bot token in-process, same
// as thinking-bubble: see `WEBSITE_BOT_TOKEN` in setup.sh's `.env` heredoc.
//
// HTML generation for the claimed follow-up message can't reuse
// `ctx.runtimeContext.llm` (that only exists on `PluginCommandContext`,
// which a hook handler never receives) -- it uses `api.runtime.llm.complete()`
// instead, captured once at `register(api)` time. Per the shipped
// `.d.ts`, `PluginRuntimeCore["llm"]` is the exact same type
// `PluginCommandContext.runtimeContext.llm` is typed as, so this should be
// the identical helper reached a different way -- plausible from the types,
// NOT independently confirmed live the way the tool-call/command-context
// findings above were (no owner Telegram access to trigger the claimed-message
// path end to end; see verification notes in the repo).

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const COOKIE_NAME = "website_k";
const TUNNEL_URL_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;
const TUNNEL_STARTUP_TIMEOUT_MS = 20_000;

/** Persistent path under the /data volume, installed there by setup.sh --
 * NOT /usr/local/bin (container writable layer, wiped on every
 * --force-recreate). See header comment for the incident this fixes. */
const CLOUDFLARED_PATH = "/data/bin/cloudflared";

/** The `website-design` skill, shipped alongside this plugin (declared via
 * `"skills": ["./skills"]` in openclaw.plugin.json, "always": true in its
 * own frontmatter) so it's always name-discoverable in the compact
 * `<available_skills>` entry every turn gets.
 *
 * Its FULL BODY is no longer relied on to reach the main agent turn (the
 * path `publish_website` itself is reached through: the agent generates
 * HTML itself, per AGENTS.md's addendum, then calls the tool with it -- the
 * tool handler here never talks to the LLM at all) via progressive-
 * disclosure skill discovery. That mechanism was live-measured (08-19) to
 * cost a real, unconditional round trip on a cold session: agent turn 1
 * decides to `read` the skill file, turn 2 (only after that result comes
 * back) finally decides to call `publish_website` -- a ~7s gap between the
 * two tool-call dispatch timestamps in the same run, before any real page
 * content gets generated. See the `before_prompt_build` hook registered in
 * register() below for the fix: this file is now read directly at request
 * time (loadDesignGuidance below) for THREE call sites, not two -- that
 * hook (main agent-turn path), generateHtml() (/website fast path), and the
 * reply_dispatch claimed-follow-up handler -- one file, one read function,
 * no copy to drift, and no agent-side discovery step required for any of
 * them. The skill declaration stays (cheap, and keeps the compact entry
 * available in case a future turn wants to `read` it explicitly for some
 * reason), it's just no longer load-bearing for getting the full body in
 * front of the model before it generates. */
const SKILL_PATH = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "skills",
  "website-design",
  "SKILL.md",
);

/** How long a bare `/website`'s "awaiting description" state stays claimable.
 * Distinct concern from sitesBySessionKey's own no-timeout policy (that one
 * governs how long a *published* site stays up -- explicit close_website
 * only, by design, see header above). This is just "how long the mic stays
 * open after I asked a question" -- a fixed few minutes is plenty; nobody
 * describing a page they just asked to build takes longer than that. */
const WEBSITE_AWAIT_TIMEOUT_MS = 5 * 60 * 1000;

/** toolCallId -> sessionKey, populated by the before_tool_call hook below and
 * consumed (and deleted) by the matching tool's execute(). This is the only
 * way to get chat/session identity into a plain (non-factory) tool's
 * execute() call in this OpenClaw version -- see header comment. */
const sessionKeyByToolCallId = new Map();

/** sessionKey -> active Site. One active website per chat/session, per the
 * product spec ("don't leak a second tunnel/process per chat"). */
const sitesBySessionKey = new Map();

/** sessionKey -> in-flight createSite() Promise. Reserved synchronously
 * before the first await, so two publish_website calls that race for the
 * same session join the same tunnel/server creation instead of each
 * spawning their own (orphaning one on whichever `set()` lost the race). */
const pendingCreations = new Map();

/** Cap on sessionKeyByToolCallId's size: entries are only removed when
 * execute() runs, so a toolCallId whose execute() never fires (blocked by
 * another hook, aborted, etc.) would otherwise leak forever. Evicting the
 * oldest entry past this bound keeps it bounded without needing a TTL
 * timer. */
const MAX_TRACKED_TOOL_CALLS = 50;

/** sessionKey -> { since }. Set by a bare `/website`, consumed by the
 * reply_dispatch handler below when the next plain-text message for that
 * session arrives (claimed as the description), cleared early by any slash
 * command for that session, and evicted past WEBSITE_AWAIT_TIMEOUT_MS. See
 * header comment for why this is reply_dispatch-based rather than
 * inbound_claim-based. */
const awaitingDescriptionBySessionKey = new Map();

function timingSafeTokenEqual(candidate, real) {
  if (typeof candidate !== "string" || typeof real !== "string" || !candidate || !real) return false;
  const a = Buffer.from(candidate, "utf8");
  const b = Buffer.from(real, "utf8");
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of header.split(";")) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const i = trimmed.indexOf("=");
    if (i < 0) continue;
    out[trimmed.slice(0, i)] = trimmed.slice(i + 1);
  }
  return out;
}

function makeRequestHandler(site) {
  return (req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { "content-type": "text/plain" }).end("method not allowed");
      return;
    }
    let url;
    try {
      url = new URL(req.url ?? "/", "http://127.0.0.1");
    } catch {
      res.writeHead(400, { "content-type": "text/plain" }).end("bad request");
      return;
    }
    const queryToken = url.searchParams.get("k");
    const cookies = parseCookies(req.headers.cookie);
    const queryOk = timingSafeTokenEqual(queryToken, site.token);
    const cookieOk = timingSafeTokenEqual(cookies[COOKIE_NAME], site.token);
    if (!queryOk && !cookieOk) {
      res.writeHead(403, { "content-type": "text/plain", "cache-control": "no-store" }).end("forbidden");
      return;
    }
    const headers = {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    };
    // Exchange the query token for a cookie on the request that carried it,
    // per the spec's "token in URL -> exchanged once for a cookie" model.
    if (queryOk) {
      headers["set-cookie"] = `${COOKIE_NAME}=${site.token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=86400`;
    }
    res.writeHead(200, headers);
    res.end(req.method === "HEAD" ? undefined : site.html);
  };
}

function waitForTunnelUrl(proc) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const onData = (chunk) => {
      buf += chunk.toString("utf8");
      const match = buf.match(TUNNEL_URL_RE);
      if (match) {
        cleanup();
        resolve(match[0]);
      }
    };
    const onExit = (code) => {
      cleanup();
      reject(new Error(`cloudflared exited before printing a tunnel URL (code ${code}): ${buf.slice(-1000)}`));
    };
    // Spawn failures (missing binary, bad permissions, ...) surface
    // asynchronously as an 'error' event on `proc`, never as a thrown
    // exception -- a try/catch around spawn() would never see this. Without
    // a listener here (or the permanent one added in createSite right after
    // spawn()), this is an unhandled EventEmitter 'error', which is fatal to
    // the whole Node process by default. This one turns it into a normal
    // rejection for this request instead.
    const onError = (err) => {
      cleanup();
      reject(new Error(`failed to start cloudflared (${CLOUDFLARED_PATH}): ${err.message}`));
    };
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`cloudflared did not print a tunnel URL within ${TUNNEL_STARTUP_TIMEOUT_MS}ms: ${buf.slice(-1000)}`));
    }, TUNNEL_STARTUP_TIMEOUT_MS);
    function cleanup() {
      clearTimeout(timer);
      proc.stdout?.off("data", onData);
      proc.stderr?.off("data", onData);
      proc.off("exit", onExit);
      proc.off("error", onError);
    }
    proc.stdout?.on("data", onData);
    proc.stderr?.on("data", onData);
    proc.on("exit", onExit);
    proc.on("error", onError);
  });
}

async function createSite(sessionKey, html, title) {
  const server = http.createServer();
  const token = crypto.randomBytes(24).toString("base64url");
  const site = { sessionKey, server, token, html, title, cloudflaredProc: null, tunnelUrl: null };
  server.on("request", makeRequestHandler(site));

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve(undefined);
    });
  });
  const port = server.address().port;

  // Cheap upfront check for the common case (binary genuinely missing, e.g.
  // a container recreation that predates this fix) so the reported error is
  // immediate and specific rather than whatever spawn()'s ENOENT happens to
  // say. Not a substitute for the 'error' handlers below -- this can't catch
  // every failure mode (permissions, a binary that vanishes between the
  // check and the spawn, etc.), just the most common one, faster.
  if (!fs.existsSync(CLOUDFLARED_PATH)) {
    try {
      server.close();
    } catch {
      // already closed
    }
    throw new Error(`cloudflared not found at ${CLOUDFLARED_PATH} -- was setup.sh's install step run?`);
  }

  const proc = spawn(CLOUDFLARED_PATH, ["tunnel", "--url", `http://127.0.0.1:${port}`], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  site.cloudflaredProc = proc;
  // Permanent listener for the life of this process (not just the startup
  // window waitForTunnelUrl below covers) -- an EventEmitter's 'error' event
  // is fatal to the whole gateway process if nothing is ever listening, and
  // waitForTunnelUrl's own listener is removed once startup finishes. This
  // is the actual fix for the incident described in the header comment:
  // whatever goes wrong with this child process, ever, gets logged for this
  // one session instead of taking down every other conversation.
  proc.on("error", (err) => {
    console.error(`[website] cloudflared process error (session ${sessionKey}):`, err.message);
  });
  // cloudflared can die on its own (network blip, process limits); if that
  // happens while we're still tracking this site, stop pretending it's
  // live so the next publish_website actually recreates a working tunnel
  // instead of silently returning a dead link.
  proc.on("exit", () => {
    if (sitesBySessionKey.get(sessionKey) === site) {
      sitesBySessionKey.delete(sessionKey);
      try {
        server.close();
      } catch {
        // already closed
      }
    }
  });

  try {
    site.tunnelUrl = await waitForTunnelUrl(proc);
  } catch (err) {
    try {
      proc.kill("SIGTERM");
    } catch {
      // already dead
    }
    try {
      server.close();
    } catch {
      // already closed
    }
    throw err;
  }

  sitesBySessionKey.set(sessionKey, site);
  return site;
}

function closeSite(site) {
  try {
    site.cloudflaredProc?.kill("SIGTERM");
  } catch {
    // already dead
  }
  try {
    site.server.close();
    site.server.closeAllConnections?.();
  } catch {
    // already closed
  }
}

function sessionKeyForToolCall(toolCallId) {
  const sessionKey = sessionKeyByToolCallId.get(toolCallId);
  sessionKeyByToolCallId.delete(toolCallId);
  return sessionKey ?? "global";
}

const publishParameters = {
  type: "object",
  required: ["html"],
  properties: {
    html: {
      type: "string",
      description:
        "A complete, self-contained HTML document (inline CSS/JS, no external build step or assets).",
    },
    title: {
      type: "string",
      description: "Optional short title for this page, used only for logging.",
    },
  },
};

const closeParameters = {
  type: "object",
  properties: {},
};

/** Shared by publish_website (tool) and the /website command: reuse the
 * currently open site for this session if one exists, otherwise create one.
 * Callers are responsible for resolving `sessionKey` first (differs by
 * caller -- see header comment for the tool's toolCallId->sessionKey path
 * and the command handler's direct ctx.sessionKey). */
async function publishForSession(sessionKey, html, title) {
  let reused = true;
  let creating = pendingCreations.get(sessionKey);
  if (!sitesBySessionKey.has(sessionKey) && !creating) {
    reused = false;
    creating = createSite(sessionKey, html, title);
    pendingCreations.set(sessionKey, creating);
    // .finally() returns a NEW promise that mirrors creating's rejection --
    // `creating` itself is properly handled by the `await creating` below
    // (or by whichever concurrent caller joined this same in-flight
    // creation), but this discarded `.finally()` promise is not awaited by
    // anyone. Left uncaught, that's a second, independent unhandled
    // rejection for the exact same failure -- and an unhandled rejection is
    // fatal to the whole process by default, same as the unhandled
    // ChildProcess 'error' event this file otherwise guards against. Caught
    // live by scripts/test-website-crash-safety.mjs -- run it after
    // touching this function.
    creating.finally(() => pendingCreations.delete(sessionKey)).catch(() => {});
  }

  const site = creating ? await creating : sitesBySessionKey.get(sessionKey);
  site.html = html;
  site.title = title;

  const url = `${site.tunnelUrl}/?k=${site.token}`;
  return { url, reused };
}

/** Strip a ```html ... ``` (or bare ```) fence the model may wrap its output
 * in despite being told not to -- cheap insurance, not a parser. */
function stripCodeFence(text) {
  const trimmed = text.trim();
  const match = trimmed.match(/^```(?:html)?\s*\n([\s\S]*?)\n?```$/i);
  return match ? match[1] : trimmed;
}

const WEBSITE_COMMAND_SYSTEM_PROMPT_BASE =
  "You build a single self-contained HTML page on request. Output ONLY the raw HTML document " +
  "(starting with <!DOCTYPE html> or <html>) -- no markdown code fences, no commentary before or " +
  "after. Inline all CSS and JS; do not reference external files or a build step.";

/** Cached after first read -- this only changes on a redeploy, and
 * generateHtml() may run often within one gateway process lifetime. `null`
 * means "already tried, file unavailable" so a missing/broken skill file
 * degrades to the bare base prompt instead of retrying a failing read (and
 * logging a warning) on every single generation. */
let cachedDesignGuidance;

/** Reads the `website-design` skill's own body (see SKILL_PATH comment
 * above) and strips its YAML frontmatter, so the exact same design-system
 * text that ships as a real OpenClaw skill also gets folded directly into
 * the system prompt for the two generation paths that bypass skill
 * injection entirely. One file, no second copy to drift out of sync. */
function loadDesignGuidance() {
  if (cachedDesignGuidance !== undefined) return cachedDesignGuidance;
  try {
    const raw = fs.readFileSync(SKILL_PATH, "utf8");
    const body = raw.replace(/^---\n[\s\S]*?\n---\n/, "").trim();
    cachedDesignGuidance = body;
  } catch (err) {
    console.error(
      `[website] couldn't read design skill at ${SKILL_PATH}, generating with the bare prompt instead:`,
      err instanceof Error ? err.message : String(err),
    );
    cachedDesignGuidance = "";
  }
  return cachedDesignGuidance;
}

function buildWebsiteCommandSystemPrompt() {
  const guidance = loadDesignGuidance();
  return guidance ? `${WEBSITE_COMMAND_SYSTEM_PROMPT_BASE}\n\n${guidance}` : WEBSITE_COMMAND_SYSTEM_PROMPT_BASE;
}

/** Plain text, not markdown -- this goes through the normal command-reply
 * pipeline, which nothing else in this file assumes renders markdown. */
const WEBSITE_INTRO =
  "Website: I build a real, live page from your description -- a dashboard, a form, a small " +
  "internal tool, a landing page, whatever you can picture -- and publish it as a link you can " +
  "open right now. No setup, no build step, just describe it.\n\n" +
  "Send your description as your next message: what it should do, what it should show, how it " +
  "should look if you care. I'll generate it and hand you the link.\n\n" +
  "Already have a site open in this chat? A new description replaces it -- one live page per " +
  "chat at a time.";

/** Shared by the fast path (/website <description> in one message) and the
 * claimed-follow-up path (reply_dispatch below): turn a description into
 * raw HTML via whichever llm.complete() the caller has access to.
 *
 * --- Prompt caching investigation (08-19), UPDATED with live results ---
 *
 * The design guidance folded into systemPrompt above is large (~4.7KB,
 * ~1,150 tokens) and byte-identical on every single call, so in principle
 * this is exactly the shape Gemini's *implicit* caching wants -- on by
 * default for Gemini 2.5+ models, zero client-side setup, and Google's own
 * guidance is "keep the content at the beginning of the request the same."
 *
 * - OpenClaw's plugin-SDK `llm.complete()` has a typed `cacheRetention`
 *   option, but it's dead for this transport -- confirmed by reading the
 *   real shipped transport code: `buildGoogleGenerativeAiParams` never
 *   reads it. The actual Gemini *explicit* cache create/manage path
 *   (`cachedContents`) exists in this OpenClaw build but only for the
 *   embedded agent-turn runner's own session pipeline, with zero plugin
 *   entry point -- a plugin would have to bypass the SDK and hand-roll
 *   Gemini's raw `cachedContents` REST lifecycle itself to get *explicit*
 *   caching. Not done here: substantially bigger, riskier engineering than
 *   what follows shows is actually justified.
 * - The `before_prompt_build` hook above originally used
 *   `appendSystemContext`, which -- traced through this build's own
 *   `composeSystemPromptWithHookContext` -- lands AFTER the per-turn
 *   variable base system prompt, not before it, defeating the whole
 *   "stable prefix" premise. Fixed to `prependSystemContext`, which this
 *   build's own code confirms puts it first, ahead of everything variable.
 * - With that fix live, ran 7 real `openclaw agent --local` calls against
 *   this deployed box (4 pre-fix, 3 post-fix, spanning a cold-cache
 *   container restart and immediate back-to-back repeats) -- every single
 *   one logged `cacheRead: 0` in the real Gemini `usageMetadata`
 *   (`cachedContentTokenCount`, read directly off the wire by this build's
 *   `updateUsage()` in the google transport, not something our code could
 *   fake even if it tried). Prefix was correctly positioned, well over the
 *   documented 1,024-token minimum, and byte-identical across calls --
 *   implicit caching still never engaged, empirically, in this
 *   environment.
 * - Conclusion: implicit caching is real but opaque and best-effort on
 *   Google's side -- it depends on backend cache state this low-volume
 *   BYOK single-tenant sandbox (occasional requests, minutes apart, no
 *   sustained QPS to keep a shard's cache warm) has no way to influence or
 *   guarantee, and OpenClaw exposes no plugin-level lever to force it
 *   (`cacheRetention` is dead for this transport, `cachedContents` has no
 *   plugin entry point). Given that, this is genuinely NOT achievable as a
 *   reliable, verifiable win from the plugin side right now -- reporting
 *   it as such rather than leaving it an unverified assumption. What *is*
 *   real and shipped: the request is now correctly shaped for caching
 *   (prefix position fixed) if Google's infra ever does warm up for this
 *   traffic pattern, and `usage.cacheRead` is logged on every call so a
 *   hit becomes visible the moment one happens, instead of being silently
 *   assumed either way. */
async function generateHtml(llm, description) {
  const completion = await llm.complete({
    messages: [{ role: "user", content: description }],
    systemPrompt: buildWebsiteCommandSystemPrompt(),
    purpose: "website.command.generate",
    maxTokens: 8192,
    temperature: 0.4,
  });
  const cacheRead = completion.usage?.cacheRead ?? 0;
  console.log(
    `[website] generateHtml usage: input=${completion.usage?.input ?? "?"} cacheRead=${cacheRead} output=${completion.usage?.output ?? "?"}`,
  );
  return stripCodeFence(completion.text ?? "");
}

/** Direct Telegram Bot API call -- the same pattern thinking-bubble/index.ts
 * already proved live, used here because the reply_dispatch handler below
 * delivers its reply directly rather than through the dispatcher's own
 * sendFinalReply (see header comment). */
async function tg(botToken, method, body) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!json.ok) {
    throw new Error(`Telegram ${method} failed: ${json.description ?? res.status}`);
  }
  return json;
}

/** Cross-plugin coordination key thinking-bubble/index.ts publishes on
 * `globalThis` -- see that file's "Fix: reply_dispatch-delivered replies"
 * header section and its `getReplyDispatchSettler` doc comment for the full
 * reasoning (reply_dispatch's claim-is-terminal semantics rule out
 * thinking-bubble registering its own reply_dispatch handler for this, and
 * there's no import path between separate workspace-extension plugin
 * directories). Must stay byte-identical to that file's copy of the same
 * string (Symbol.for interns by exact string match) and to
 * plugins/quick-menu/index.ts's copy. */
const THINKING_BUBBLE_SETTLER_KEY = Symbol.for("openclaw-byok.thinking-bubble.getReplyDispatchSettler");

/** Looks up thinking-bubble's settle function by the well-known symbol above
 * and calls it for this session, if present. Safe no-op if thinking-bubble
 * isn't loaded/enabled (lookup misses) or has no placeholder pending for
 * this session (the inner call returns undefined) -- callers use this as
 * `getThinkingBubbleSettler(sessionKey)?.()`. */
function getThinkingBubbleSettler(sessionKey) {
  const getSettler = globalThis[THINKING_BUBBLE_SETTLER_KEY];
  return typeof getSettler === "function" ? getSettler(sessionKey) : undefined;
}

/** `reply_dispatch`'s event carries a `FinalizedMsgContext` (confirmed
 * against this deployed OpenClaw version's own `src/auto-reply/
 * templating.ts`) -- a different shape from `message_received`'s event/ctx
 * pair the old extraction helpers here targeted. Body-field priority
 * (BodyForCommands > CommandBody > RawBody > Body) matches the exact chain
 * ai-farm/plugins/wizbid-tools/index.cjs uses for command detection off this
 * same hook. */
function resolveReplyDispatchBody(finalizedCtx) {
  const body =
    finalizedCtx.BodyForCommands ?? finalizedCtx.CommandBody ?? finalizedCtx.RawBody ?? finalizedCtx.Body ?? "";
  return body.trim();
}

/** Chat-id chain: `ChatId` first (the field templating.ts documents as the
 * "provider-native chat/conversation id"), then the same SenderId/From/To
 * fallback chain ai-farm/plugins/shared/telegram-helpers.cjs's own
 * `resolveChatId` uses against this same hook -- for a Telegram DM (this
 * product's only supported chat type) the sender id and chat id are the
 * same value. */
function resolveReplyDispatchChatId(finalizedCtx) {
  const candidates = [finalizedCtx.ChatId, finalizedCtx.SenderId, finalizedCtx.From, finalizedCtx.To];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim().length > 0) return c.trim();
  }
  return undefined;
}

export default definePluginEntry({
  id: "website",
  name: "Website",
  description: "Publish a self-contained HTML page as a live, token-gated website and close it when done.",
  register(api) {
    // Lazily checking the timeout inside reply_dispatch (below) only
    // evicts an awaiting-state entry when a follow-up message actually
    // arrives for that session -- a bare `/website` nobody ever answers
    // would otherwise sit in the Map forever. This sweep is what makes
    // WEBSITE_AWAIT_TIMEOUT_MS an actual timeout rather than a check that
    // only fires when it's already moot. unref() so it can't keep the
    // process alive on its own.
    setInterval(() => {
      const now = Date.now();
      for (const [sessionKey, awaiting] of awaitingDescriptionBySessionKey) {
        if (now - awaiting.since > WEBSITE_AWAIT_TIMEOUT_MS) {
          awaitingDescriptionBySessionKey.delete(sessionKey);
        }
      }
    }, 60_000).unref();

    // Observation-only: stash the session key for this tool call so
    // execute() (which gets no context of its own) can look it up by
    // toolCallId. See header comment for why this is the mechanism, not
    // the factory form of registerTool.
    api.on("before_tool_call", (event, ctx) => {
      if (
        (event.toolName === "publish_website" || event.toolName === "close_website") &&
        event.toolCallId
      ) {
        if (sessionKeyByToolCallId.size >= MAX_TRACKED_TOOL_CALLS) {
          const oldestKey = sessionKeyByToolCallId.keys().next().value;
          sessionKeyByToolCallId.delete(oldestKey);
        }
        sessionKeyByToolCallId.set(event.toolCallId, ctx?.sessionKey ?? "global");
      }
    });

    // --- Killing the skill-read round-trip (08-19) ---
    //
    // Confirmed real via `PluginHookBeforePromptBuildResult` in this
    // deployed version's own shipped `.d.ts` (not guessed from the docs
    // alone): `before_prompt_build` fires before every agent turn's system
    // prompt is built and can return `prependSystemContext`/
    // `appendSystemContext`, whose doc comments both say the same thing --
    // "so providers can cache it (e.g. prompt caching). Use for static
    // plugin guidance instead of prependContext/appendContext to avoid
    // per-turn token cost."
    //
    // Started with `appendSystemContext`, then live-measured (08-19, 4
    // consecutive real `openclaw agent --local` calls against this
    // deployed box) that it produced `cacheRead: 0` every single time
    // despite a stable ~5KB guidance block on every turn. Traced the real
    // cause by reading this build's own shipped
    // `composeSystemPromptWithHookContext` (attempt.thread-helpers-*.js):
    // it joins the request as `[prependSystem, baseSystemPrompt,
    // appendSystem]` -- so `appendSystemContext` lands AFTER the base
    // system prompt (tool defs, AGENTS.md, current date/time, session
    // state), which varies turn to turn. Gemini's implicit caching keys
    // off a stable prefix at the very START of the request (see
    // generateHtml() below); putting the static block at the *end* means
    // the actual prefix the cache would need to match is the *variable*
    // part, so it can never hit. `prependSystemContext` puts it first,
    // ahead of all per-turn-variable content -- the shape caching actually
    // needs. This is a real fix for a real bug in the first version of
    // this hook, not a guess: same call sites, same guidance text, just
    // moved to the position that makes the cache-worthy prefix actually
    // stable.
    //
    // This reuses loadDesignGuidance() unchanged -- the exact same read
    // that already feeds generateHtml()'s systemPrompt for the /website
    // fast path and the reply_dispatch follow-up -- so all three call sites
    // share one source of truth. The agent no longer has any reason to
    // issue a `read` tool call for the skill body before calling
    // `publish_website`: the guidance is already in front of it when it
    // decides whether to build a page at all (confirmed live -- see
    // generateHtml() below for the full caching investigation and its
    // results).
    //
    // Registered for every turn of the agent this plugin is loaded into
    // (there's no cheaper per-turn way to know in advance whether *this*
    // turn will end up building a page -- that's the same reason the
    // model needed a skill-read before, just moved earlier), which is a
    // real, small, ongoing prompt-size cost (loadDesignGuidance()'s body,
    // ~5KB) traded for eliminating the round trip on every turn that does
    // end up calling `publish_website`.
    api.on("before_prompt_build", async () => {
      const guidance = loadDesignGuidance();
      if (!guidance) return;
      return { prependSystemContext: guidance };
    });

    // Claims the next plain-text message after a bare `/website` as the
    // description, generates+publishes it, and replies directly -- see the
    // big header comment's "Fix (round 2)" section for why reply_dispatch
    // (a structural short-circuit, confirmed against this deployed
    // version's own dispatch-from-config.ts) rather than message_received
    // (round 1, an observer hook that let a stray LLM reply through) or
    // inbound_claim (real but gated behind an owner-approval binding flow
    // that doesn't fit this UX).
    api.on(
      "reply_dispatch",
      async (event, ctx) => {
        const finalizedCtx = event.ctx ?? {};
        const sessionKey = event.sessionKey ?? finalizedCtx.SessionKey;
        if (!sessionKey) return;

        const awaiting = awaitingDescriptionBySessionKey.get(sessionKey);
        if (!awaiting) return;

        const text = resolveReplyDispatchBody(finalizedCtx);

        // Any slash command -- /website again, /close, anything -- cancels
        // the wait rather than being misread as a description, and falls
        // through (undefined return) so native/agent dispatch still
        // processes it normally.
        if (text.startsWith("/")) {
          awaitingDescriptionBySessionKey.delete(sessionKey);
          return;
        }

        if (Date.now() - awaiting.since > WEBSITE_AWAIT_TIMEOUT_MS) {
          awaitingDescriptionBySessionKey.delete(sessionKey);
          return;
        }

        if (!text) return;

        // Claim it now, before any await, so a duplicate/retried event for
        // the same message can't double-fire this.
        awaitingDescriptionBySessionKey.delete(sessionKey);

        const provider = finalizedCtx.Provider;
        const chatId = resolveReplyDispatchChatId(finalizedCtx);
        const botToken = process.env.WEBSITE_BOT_TOKEN;
        const llm = api.runtime?.llm;

        if (provider !== "telegram" || !chatId || !botToken || !llm) {
          console.error(
            "[website] can't handle claimed follow-up description: missing telegram identity, bot token, or llm runtime",
          );
          return;
        }

        // Captured now, before generateHtml()'s (possibly slow) LLM call --
        // see getReplyDispatchSettler's doc comment in thinking-bubble's
        // index.ts for why "early capture, late invoke" is what makes this
        // safe against a newer placeholder replacing this one mid-generation.
        const settleThinkingBubble = getThinkingBubbleSettler(sessionKey);

        if (ctx.onReplyStart) await ctx.onReplyStart();

        try {
          const html = await generateHtml(llm, text);
          const published = await publishForSession(sessionKey, html, text.slice(0, 80));
          // Delete the placeholder right before the real answer is sent as a
          // fresh message -- same timing thinking-bubble's own
          // reply_payload_sending path uses for the normal agent-turn case.
          settleThinkingBubble?.();
          await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text: `${published.reused ? "Website updated" : "Website published"}: ${published.url}`,
          });
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          try {
            // A real reply (the error text) is still about to be delivered
            // via reply_dispatch, so the placeholder settles here too --
            // otherwise the 3-minute safety net would eventually replace it
            // with a misleading "didn't come through" next to this error.
            settleThinkingBubble?.();
            await tg(botToken, "sendMessage", {
              chat_id: chatId,
              text: `Couldn't build that page: ${message}`,
            });
          } catch (sendErr) {
            console.error(
              "[website] failed to report generation error to chat:",
              sendErr instanceof Error ? sendErr.message : String(sendErr),
            );
          }
        }

        // Delivered directly via the Telegram API above (not through
        // dispatcher.sendFinalReply), so queuedFinal is false and the lane
        // is released explicitly via markIdle -- same shape reseller-tools
        // uses for its own tgFetch-delivered commands (the fix for the
        // "lane stuck in `processing` for 11-30s after a handled command"
        // bug, commit 8146b2e per the memory file).
        ctx.dispatcher.markComplete();
        ctx.recordProcessed("completed");
        ctx.markIdle("website_followup_handled");
        return { handled: true, queuedFinal: false, counts: ctx.dispatcher.getQueuedCounts() };
      },
      { priority: 10 },
    );

    api.registerTool({
      name: "publish_website",
      label: "Publish Website",
      description:
        "Publish a self-contained HTML page (a dashboard, form, or small interactive tool) as a live, securely-reachable website and return its link to share with the user. Reuses and replaces the currently open page for this chat if one is already open.",
      parameters: publishParameters,
      async execute(toolCallId, params) {
        const sessionKey = sessionKeyForToolCall(toolCallId);
        const html = String(params.html ?? "");
        const title = typeof params.title === "string" ? params.title : undefined;

        // Reserving the pendingCreations slot happens inside
        // publishForSession, synchronously before its first await, so a
        // second publish_website call for this same session (racing in the
        // same turn, or a retry) joins this creation instead of spawning
        // its own tunnel/server -- see pendingCreations comment.
        //
        // Unlike the other two callers of publishForSession (the /website
        // command handler and the claimed-follow-up message_received
        // handler), this one previously had no try/catch: an uncaught
        // rejection here becomes an unhandled promise rejection, which is
        // also fatal to the whole process by default (not the EventEmitter
        // 'error' path this file otherwise guards against, but the same
        // failure mode from this tool's point of view). Report it as a
        // normal failed tool call instead.
        try {
          const { url, reused } = await publishForSession(sessionKey, html, title);
          return {
            content: [{ type: "text", text: `${reused ? "Website updated" : "Website published"}: ${url}` }],
            details: { url, reused },
          };
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          return {
            content: [{ type: "text", text: `Couldn't publish that page: ${message}` }],
            details: { url: null, reused: false, error: message },
          };
        }
      },
    });

    api.registerTool({
      name: "close_website",
      label: "Close Website",
      description: "Tear down the currently published website for this chat, if one is open.",
      parameters: closeParameters,
      async execute(toolCallId) {
        const sessionKey = sessionKeyForToolCall(toolCallId);
        const site = sitesBySessionKey.get(sessionKey);
        if (!site) {
          return {
            content: [{ type: "text", text: "No active website to close." }],
            details: { closed: false },
          };
        }
        sitesBySessionKey.delete(sessionKey);
        closeSite(site);
        return {
          content: [{ type: "text", text: "Website closed." }],
          details: { closed: true },
        };
      },
    });

    // --- /website slash command ---
    //
    // Two designs were viable per the SDK's own types: (1) light preprocessing
    // + `continueAgent: true`, letting the normal agent turn generate the HTML
    // and call publish_website itself, or (2) the handler generates the HTML
    // itself via the runtime's LLM-completion helper and publishes directly,
    // fully bypassing the agent loop. Went with (2): `continueAgent`'s prompt-
    // passing mechanics (does the continued turn see the raw `/website ...`
    // text, or something rewritten by this handler?) are undocumented -- not
    // one line about it beyond a single feature-matrix table cell in
    // sdk-overview.md -- and it appears in ZERO of the bundled extensions that
    // register commands (memory-core, device-pair, workboard, phone-control,
    // talk-voice, active-memory all grepped clean for it). Design (2), by
    // contrast, is a real documented path: `PluginCommandContext.runtimeContext.llm`
    // is typed as `PluginRuntimeCore["llm"]`, the exact same `.complete({messages,
    // purpose, maxTokens, temperature}) -> {text, ...}` helper sdk-runtime.md
    // documents and gives a working example of. Simpler, deterministic, and
    // actually confirmed to exist -- not chosen by default, chosen because the
    // alternative couldn't be confirmed real without guessing at unstated
    // continuation semantics on a product-facing command.
    api.registerCommand({
      name: "website",
      description: "Build a page from your description and publish it as a live website.",
      acceptsArgs: true,
      handler: async (ctx) => {
        const description = (ctx.args ?? "").trim();
        const sessionKey = ctx.sessionKey ?? "global";

        if (!description) {
          // Explain, then wait for the next message as input -- see header
          // comment and WEBSITE_AWAIT_TIMEOUT_MS for the claiming mechanism
          // and its timeout.
          awaitingDescriptionBySessionKey.set(sessionKey, { since: Date.now() });
          return {
            text: WEBSITE_INTRO,
            continueAgent: false,
          };
        }

        // A real description arrived inline (the fast path) -- any stale
        // awaiting-state from an earlier bare /website in this session no
        // longer applies.
        awaitingDescriptionBySessionKey.delete(sessionKey);

        const llm = ctx.runtimeContext?.llm;
        if (!llm) {
          return {
            text: "Website generation isn't available in this session (no LLM runtime context).",
            continueAgent: false,
          };
        }

        let html;
        try {
          html = await generateHtml(llm, description);
        } catch (err) {
          return {
            text: `Couldn't generate that page: ${err instanceof Error ? err.message : String(err)}`,
            continueAgent: false,
          };
        }

        let published;
        try {
          published = await publishForSession(sessionKey, html, description.slice(0, 80));
        } catch (err) {
          return {
            text: `Generated the page but couldn't publish it: ${err instanceof Error ? err.message : String(err)}`,
            continueAgent: false,
          };
        }

        return {
          text: `${published.reused ? "Website updated" : "Website published"}: ${published.url}`,
          continueAgent: false,
        };
      },
    });
  },
});

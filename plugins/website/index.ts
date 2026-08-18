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
// Fallback, per the same design note that anticipated this: use
// `message_received` (proven live in thinking-bubble/index.ts) to notice
// the next plain-text message after a bare `/website` and independently
// generate+publish+reply to it. This hook is observation-only -- it cannot
// stop the normal agent turn from *also* seeing that same plain text and
// replying to it conversationally, since there's no special instruction in
// front of the model telling it a command is mid-flow. That's a real,
// visible degradation (the user may get two replies to one message: our
// direct "Website published: ..." send, and a separate generic chat reply)
// -- not something silently treated as equivalent to the win-the-race
// language in the design brief. Flag this to whoever does the live Telegram
// test; if it's too noisy in practice the next step would be chasing
// `before_agent_run` (currently dead in this build, see thinking-bubble's
// header) or asking upstream for an unscoped `inbound_claim` invocation.
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
import { spawn } from "node:child_process";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const COOKIE_NAME = "website_k";
const TUNNEL_URL_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;
const TUNNEL_STARTUP_TIMEOUT_MS = 20_000;

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
 * message_received handler below when the next plain-text message for that
 * session arrives (claimed as the description), cleared early by any slash
 * command for that session, and evicted past WEBSITE_AWAIT_TIMEOUT_MS. See
 * header comment for why this is message_received-based rather than
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
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`cloudflared did not print a tunnel URL within ${TUNNEL_STARTUP_TIMEOUT_MS}ms: ${buf.slice(-1000)}`));
    }, TUNNEL_STARTUP_TIMEOUT_MS);
    function cleanup() {
      clearTimeout(timer);
      proc.stdout?.off("data", onData);
      proc.stderr?.off("data", onData);
      proc.off("exit", onExit);
    }
    proc.stdout?.on("data", onData);
    proc.stderr?.on("data", onData);
    proc.on("exit", onExit);
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

  const proc = spawn("cloudflared", ["tunnel", "--url", `http://127.0.0.1:${port}`], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  site.cloudflaredProc = proc;
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
    creating.finally(() => pendingCreations.delete(sessionKey));
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

const WEBSITE_COMMAND_SYSTEM_PROMPT =
  "You build a single self-contained HTML page on request. Output ONLY the raw HTML document " +
  "(starting with <!DOCTYPE html> or <html>) -- no markdown code fences, no commentary before or " +
  "after. Inline all CSS and JS; do not reference external files or a build step.";

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
 * claimed-follow-up path (message_received below): turn a description into
 * raw HTML via whichever llm.complete() the caller has access to. */
async function generateHtml(llm, description) {
  const completion = await llm.complete({
    messages: [{ role: "user", content: description }],
    systemPrompt: WEBSITE_COMMAND_SYSTEM_PROMPT,
    purpose: "website.command.generate",
    maxTokens: 8192,
    temperature: 0.4,
  });
  return stripCodeFence(completion.text ?? "");
}

/** Direct Telegram Bot API call -- the same pattern thinking-bubble/index.ts
 * already proved live, used here because the message_received handler below
 * has no return-value reply channel of its own (see header comment). */
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

/** Same extraction pattern as thinking-bubble/index.ts's extractChatId --
 * message_received's real runtime event carries more candidate fields than
 * its shipped .d.ts type does, hence the defensive fan-out rather than
 * trusting a single typed field. */
function extractChatId(event, ctx) {
  const metadata = event.metadata ?? {};
  const candidates = [
    metadata.senderId,
    event.chatId,
    event.senderId,
    ctx.chatId,
    ctx.senderId,
    ctx.channelContext?.chat?.id,
  ];
  for (const c of candidates) {
    if (c !== undefined && c !== null && String(c).length > 0) return String(c);
  }
  return undefined;
}

function extractProvider(event, ctx) {
  const metadata = event.metadata ?? {};
  return metadata.provider ?? event.channel ?? ctx.messageProvider ?? ctx.channel;
}

export default definePluginEntry({
  id: "website",
  name: "Website",
  description: "Publish a self-contained HTML page as a live, token-gated website and close it when done.",
  register(api) {
    // Lazily checking the timeout inside message_received (below) only
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

    // Claims the next plain-text message after a bare `/website` as the
    // description, generates+publishes it, and replies directly -- see the
    // big header comment for why message_received (proven live) rather than
    // inbound_claim (real but gated behind an owner-approval binding flow
    // that doesn't fit this UX). Observation-only: cannot stop the model
    // from also seeing and replying to this same message -- flagged, not
    // hidden.
    api.on(
      "message_received",
      async (event, ctx) => {
        const sessionKey = event?.sessionKey ?? ctx?.sessionKey;
        if (!sessionKey) return;

        const awaiting = awaitingDescriptionBySessionKey.get(sessionKey);
        if (!awaiting) return;

        const text = typeof event?.content === "string" ? event.content.trim() : "";

        // Any slash command -- /website again, /close, anything -- cancels
        // the wait rather than being misread as a description.
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

        const provider = extractProvider(event ?? {}, ctx ?? {});
        const chatId = extractChatId(event ?? {}, ctx ?? {});
        const botToken = process.env.WEBSITE_BOT_TOKEN;
        const llm = api.runtime?.llm;

        if (provider !== "telegram" || !chatId || !botToken || !llm) {
          console.error(
            "[website] can't handle claimed follow-up description: missing telegram identity, bot token, or llm runtime",
          );
          return;
        }

        try {
          const html = await generateHtml(llm, text);
          const published = await publishForSession(sessionKey, html, text.slice(0, 80));
          await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text: `${published.reused ? "Website updated" : "Website published"}: ${published.url}`,
          });
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          try {
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
        const { url, reused } = await publishForSession(sessionKey, html, title);
        return {
          content: [{ type: "text", text: `${reused ? "Website updated" : "Website published"}: ${url}` }],
          details: { url, reused },
        };
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

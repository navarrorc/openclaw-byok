// Thinking Bubble plugin
//
// Replicates the FarmOps/Nelita pattern: send a placeholder message the
// instant a reply starts generating, then delete that message right before
// the real answer is delivered as a fresh message. It should visibly
// disappear, not turn into the answer in place (Rob, 08-18: "it stays
// around, and it should disappear"). No LLM involvement -- this is plain
// code that runs on every turn, not a prompt instruction the model has to
// remember to follow (that approach was tried and proved unreliable -- see
// ARCHITECTURE.md).
//
// Uses the Telegram Bot API directly (sendMessage / deleteMessage), the
// same way FarmOps' own bridge does it -- OpenClaw's plugin hooks give us
// the right moments to act (message_received, reply_payload_sending), but
// the actual send/delete calls are just plain HTTPS, nothing
// framework-specific.
//
// --- Quick-menu keyboard: fully decoupled from this file now ---
//
// Two prior versions of this plugin attached the quick-menu
// ReplyKeyboardMarkup to this file's placeholder message -- first as a
// plain send-then-delete placeholder, then as a "permanent carrier"
// placeholder that got edited-in-place instead of deleted. Both were
// wrong for the same underlying reason, confirmed against FarmOps'
// own hard-won 2026-07-25 lesson (`ai-farm/scripts/bridge_common.py`
// clear_chat's docstring): a keyboard-carrying message must never be
// something that gets deleted OR edited away, full stop -- not "deleted
// less often" or "edited instead of deleted", but never touched again
// after it's sent. Coupling the keyboard to this placeholder's lifecycle
// at all was the mistake, regardless of which specific lifecycle event
// (delete vs. edit) triggered the loss Rob's real device testing (08-18)
// kept turning up. The fix lives entirely in plugins/quick-menu/index.ts
// now: a standalone message it sends directly on /start and /new,
// completely independent of this file's send-then-delete placeholder.
// This file has zero reply_markup involvement, matching FarmOps' own
// clean separation between its placeholder sends (TG.send_dim, never
// carries reply_markup) and its keyboard attach sites (TG.send on
// /start, /help, /new, clear_chat -- always a permanent message).
//
// Note: before_agent_run was tried first and never fired even once, for
// any real message (confirmed live 08-18) -- it's gated behind
// hooks.allowConversationAccess and something about that permission grant
// wasn't taking effect. message_received needs no special permission and
// fires on the raw inbound message before agent routing even happens, an
// earlier and simpler point to act from anyway.
//
// message_sending was tried next for the delivery-side hook and never
// fired either (confirmed live 08-18 across several real messages) --
// it appears to only cover explicit tool-initiated sends, not the normal
// agent-turn reply. reply_payload_sending is the hook that actually fires
// for a turn's final reply routed back to the originating channel.
//
// Config injection (ctx.pluginConfig) was also confirmed empty for both
// hooks in this OpenClaw version (live debug 08-18: event.context === {}).
// So the bot token and model label come from process.env instead --
// setup.sh writes them into .env, which docker-compose already passes
// through to the container.
//
// The manifest must set activation.onStartup: true (openclaw.plugin.json)
// -- this plugin has no tools/channels to give the loader a lazy trigger,
// and OpenClaw no longer startup-loads plugins implicitly. Without it,
// `openclaw plugins list` still misleadingly reports status "loaded", but
// register() is never actually called by the live gateway (confirmed live
// 08-18 via a debug log at the top of register()).
//
// The model tag (e.g. "🧠 Gemini 2.5 Flash") is baked into the PLACEHOLDER
// text only -- it's the loading indicator, shown while the real answer is
// generating, and never appears on the final answer. Do not also set
// messages.responsePrefix in config, or the tag will show up twice.
//
// Correlation is keyed by session key, not chat id -- message_received's
// event carries senderId/chatId but no sessionKey-independent id shared
// with reply_payload_sending, whose event carries sessionKey/runId/channel
// but NO chat or sender id at all (confirmed live 08-18: reply_payload_sending
// events look like {payload, kind, channel, sessionKey, runId, usageState},
// with an empty ctx). sessionKey is the one field both events share.
//
// --- Why /start is the one slash command not skipped below ---
//
// Rob's report after tapping through an earlier design on a real phone:
// "/start doesn't show the toggle button." Root cause: the categorical
// slash-command skip below (content.startsWith("/")) caught /start along
// with every other command, so it never got a placeholder at all. But
// /start is NOT one of OpenClaw's fast built-ins: confirmed by reading
// dist/commands-registry.data-BKgJ3WoC.js's native-command table (which
// lists /help, /status, /usage, /new, etc. by textAlias) -- there is no
// "start" entry anywhere in it. With no bot.command("start", ...) handler
// registered (dist/telegram-ingress-spool-Dd3cDhXe.js:989-992 only
// registers handlers for that table's entries), a real /start falls
// through to the generic message handler at :4268 -> processInboundMessage
// (:3231) -> the normal dispatch/agent-turn path, the same one plain chat
// text takes, which DOES fire reply_payload_sending. That matches the
// earlier live observation that /start produces a natural, personalized,
// LLM-generated welcome -- it's a real agent turn, not a template. So
// /start is an explicit exception to the slash-command skip below: it gets
// a placeholder like normal chat. /help, /status, /usage, /new, /tts,
// /website, and the quick-menu's own button commands all stay skipped --
// they really are instant built-ins with no reply_payload_sending. (/new
// was re-confirmed as a native built-in, not a special case, when the
// quick-menu keyboard fix was designed -- key: "new", nativeName: "new",
// textAlias: "/new", tier: "essential" in that same registry table.)

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

/** /start is the one slash command that must NOT be skipped -- see header
 * comment for why it's a real agent turn, not a fast built-in. Matches
 * bare "/start", a deep-link payload ("/start payload"), and the
 * "/start@BotName" form Telegram uses in group chats. */
function isStartCommand(content: string): boolean {
  return /^\/start(@\w+)?(\s|$)/.test(content);
}

type Placeholder = {
  chatId: string;
  messageId: number;
  since: number;
};

const pendingBySession = new Map<string, Placeholder>();

/** Safety net for a confirmed OpenClaw platform quirk (live 08-18, both
 * before and after TTS config changes, on plain "Hi" messages): the model
 * call succeeds but the turn dispatches with zero queued reply payloads --
 * [turn/kernel] logs it, no error is thrown anywhere. reply_payload_sending
 * simply never fires for that turn, so without this the placeholder from
 * message_received sits there forever with no indication anything failed.
 * Not our bug to fix (nothing in our plugin code drops the payload), but our
 * bubble needs to resolve either way. 3 minutes is comfortably past any
 * legitimate turn -- including ones with tool calls or slow providers --
 * while still turning "stuck forever" into "stuck for a few minutes, then a
 * clear message telling the user to retry". Same style of constant as
 * WEBSITE_AWAIT_TIMEOUT_MS in plugins/website/index.ts. */
const PLACEHOLDER_TIMEOUT_MS = 3 * 60 * 1000;

const STUCK_PLACEHOLDER_TEXT = "That one didn't come through -- try sending it again.";

/** Edits a placeholder that's being abandoned (past its timeout, or
 * superseded by a new message on the same session) into a plain retry
 * notice, and swallows/logs failure the same way every other Telegram call
 * in this plugin does -- there's no further recovery action to take if this
 * one fails too. */
function settleStuckPlaceholder(botToken: string, placeholder: Placeholder) {
  tg(botToken, "editMessageText", {
    chat_id: placeholder.chatId,
    message_id: placeholder.messageId,
    text: STUCK_PLACEHOLDER_TEXT,
  }).catch((err) => {
    console.error(
      "[thinking-bubble] failed to edit stuck placeholder:",
      err instanceof Error ? err.message : String(err),
    );
  });
}

function placeholderText(): string {
  const label = process.env.THINKING_BUBBLE_MODEL_LABEL;
  return label ? `🧠 ${label} <i>thinking</i>` : "<i>thinking</i>";
}

async function tg(botToken: string, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as {
    ok?: boolean;
    result?: { message_id?: number };
    description?: string;
  };
  if (!json.ok) {
    throw new Error(`Telegram ${method} failed: ${json.description ?? res.status}`);
  }
  return json;
}

function extractChatId(event: Record<string, unknown>, ctx: Record<string, unknown>): string | undefined {
  const metadata = (event as { metadata?: Record<string, unknown> }).metadata ?? {};
  const candidates = [
    (metadata as { senderId?: string | number }).senderId,
    (event as { chatId?: string | number }).chatId,
    (event as { senderId?: string | number }).senderId,
    (ctx as { chatId?: string | number }).chatId,
    (ctx as { senderId?: string | number }).senderId,
    (ctx as { channelContext?: { chat?: { id?: string | number } } }).channelContext?.chat?.id,
  ];
  for (const c of candidates) {
    if (c !== undefined && c !== null && String(c).length > 0) return String(c);
  }
  return undefined;
}

function extractProvider(event: Record<string, unknown>, ctx: Record<string, unknown>): string | undefined {
  const metadata = (event as { metadata?: Record<string, unknown> }).metadata ?? {};
  return (
    (metadata as { provider?: string }).provider ??
    (event as { channel?: string }).channel ??
    (ctx as { messageProvider?: string }).messageProvider ??
    (ctx as { channel?: string }).channel
  );
}

function extractSessionKey(event: Record<string, unknown>, ctx: Record<string, unknown>): string | undefined {
  return (
    (event as { sessionKey?: string }).sessionKey ??
    (ctx as { sessionKey?: string }).sessionKey
  );
}

/** message_received's event carries Telegram's own message send time (ms
 * since epoch, confirmed live 08-18 via dispatch source: ctx.Timestamp is
 * set from `msg.date * 1000` and flows through unchanged to the plugin
 * event's `timestamp` field). Diffing against it gives an exact,
 * self-contained placeholder-latency measurement -- no more guessing at the
 * gap from gateway log timestamps of unrelated lines. */
function extractTimestamp(event: Record<string, unknown>): number | undefined {
  const t = (event as { timestamp?: number }).timestamp;
  return typeof t === "number" ? t : undefined;
}

export default definePluginEntry({
  id: "thinking-bubble",
  name: "Thinking Bubble",
  description: "Send a placeholder Telegram message while a reply generates, then delete it once the real answer is about to arrive.",
  register(api) {
    // Sweeps for placeholders whose owning turn never called
    // reply_payload_sending (see PLACEHOLDER_TIMEOUT_MS comment above).
    // Same shape as the website plugin's awaitingDescriptionBySessionKey
    // eviction sweep: unref() so it can't keep the process alive on its own,
    // and it's the only thing that makes the timeout apply even when no
    // later event ever arrives for that session to trigger a lazy check.
    setInterval(() => {
      const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;
      if (!botToken) return;

      const now = Date.now();
      for (const [sessionKey, placeholder] of pendingBySession) {
        if (now - placeholder.since <= PLACEHOLDER_TIMEOUT_MS) continue;

        pendingBySession.delete(sessionKey); // evict first: don't act twice on the same placeholder
        settleStuckPlaceholder(botToken, placeholder);
      }
    }, 30_000).unref();

    api.on(
      "message_received",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;

        if (!botToken) return;

        const provider = extractProvider(event as Record<string, unknown>, ctx);
        const chatId = extractChatId(event as Record<string, unknown>, ctx);
        const sessionKey = extractSessionKey(event as Record<string, unknown>, ctx);

        if (provider !== "telegram" || !chatId || !sessionKey) return;

        // A prior placeholder still tracked for this session was never
        // claimed by reply_payload_sending -- ANY new message on this
        // session (command or plain text) means it's abandoned, not just
        // slow. Settle it now, independent of whether this particular
        // message will get a new placeholder of its own, rather than
        // leaving it orphaned (untracked, unedited) until the next 3-minute
        // sweep pass -- a command being the abandoning message shouldn't
        // delay that cleanup.
        const orphaned = pendingBySession.get(sessionKey);
        if (orphaned) {
          pendingBySession.delete(sessionKey);
          settleStuckPlaceholder(botToken, orphaned);
        }

        // Slash commands (OpenClaw built-ins, this product's own /website,
        // and quick-menu's keyboard shortcuts -- all literally /-prefixed
        // text, see plugins/quick-menu/index.ts) are answered instantly by
        // a non-agent path that never fires reply_payload_sending, so a
        // placeholder sent here would either orphan forever or get caught
        // by the stuck-placeholder safety net and wrongly edited to a
        // "didn't come through" retry notice next to a reply that already
        // arrived fine. Categorical skip, not a per-command allowlist --
        // Rob, 08-18: "when /commands are being executed... we should not
        // use or display the thinking bubble... The bubble would only come
        // when there's an LLM involved." /start is the one exception --
        // it's not a fast built-in, it's a real agent turn (see header
        // comment) and needs a placeholder like normal chat.
        const content = typeof (event as { content?: unknown }).content === "string"
          ? (event as { content: string }).content.trim()
          : "";
        if (content.startsWith("/") && !isStartCommand(content)) return;

        try {
          const inboundTimestamp = extractTimestamp(event as Record<string, unknown>);
          const sent = await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text: placeholderText(),
            parse_mode: "HTML",
          });
          if (typeof inboundTimestamp === "number") {
            console.log(`[thinking-bubble] placeholder sent ${Date.now() - inboundTimestamp}ms after inbound message`);
          }
          const messageId = sent.result?.message_id;
          if (typeof messageId === "number") {
            pendingBySession.set(sessionKey, { chatId, messageId, since: Date.now() });
          }
        } catch (err) {
          console.error("[thinking-bubble] failed to send placeholder:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );

    api.on(
      "reply_payload_sending",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;

        const sessionKey = extractSessionKey(event as Record<string, unknown>, ctx);

        if (!botToken || !sessionKey) return;

        const placeholder = pendingBySession.get(sessionKey);
        if (!placeholder) return; // nothing we're tracking for this session

        pendingBySession.delete(sessionKey); // one-shot: don't act twice for the same placeholder

        // Delete the placeholder and let the normal send path deliver the
        // real answer as a fresh message -- the bubble should disappear,
        // not turn into the answer in place.
        try {
          await tg(botToken, "deleteMessage", {
            chat_id: placeholder.chatId,
            message_id: placeholder.messageId,
          });
        } catch (err) {
          console.error("[thinking-bubble] failed to delete placeholder:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );
  },
});

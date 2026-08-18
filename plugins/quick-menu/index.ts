// Quick Menu plugin
//
// Sends a persistent Telegram custom keyboard (Bot API `ReplyKeyboardMarkup`
// -- the grid revealed by the toggle button next to the text input, distinct
// from the native "/" autocomplete list `setMyCommands` already populates)
// once per session, with a curated set of this product's most useful
// commands.
//
// --- Why button text IS the literal command, not a friendly label ---
//
// FarmOps' own bridges (claudeops_bridge.py, nelita_bridge.py) always use
// friendly emoji labels ("📊 Usage & Pool") translated in-process to the
// real command via a KEYBOARD_LABELS dict, then re-routed by calling their
// own handle_command() directly. That works because FarmOps owns its whole
// message pipeline in one process. This plugin doesn't: OpenClaw owns
// native command routing, and a plugin has no confirmed way to
// programmatically invoke a built-in command (`/tts`, `/usage`, ...) and
// relay its reply back. `api.runtime.gateway.request(...)` exists
// (docs/plugins/sdk-runtime.md) but is explicitly documented as restricted
// to trusted/bundled plugins -- "calls from arbitrary external plugins are
// rejected" -- and `message_received` (the one hook this plugin family
// already knows fires reliably, see thinking-bubble/index.ts and
// website/index.ts) is observation-only, the same ceiling website/index.ts
// hit designing around `inbound_claim`. So every button's `text` here is
// the exact command string a user would type (e.g. "/tts on"). Tapping one
// sends that literal text as a normal message -- indistinguishable from
// typing it by hand, hits OpenClaw's real command router with zero custom
// interception code. Less flashy than emoji labels, but reliable, and
// nothing here can produce a stray duplicate reply or a silent no-op the
// way a fragile translation layer could.
//
// --- Trigger: once per session, on the first message_received ---
//
// The docs list a `session_start` hook (reason: "new" on a genuinely fresh
// session) that would be the more precise trigger for "greet a new
// session." Not used here: this codebase has already spent real time on
// hooks that are documented but don't fire in this build (before_agent_run,
// message_sending -- see thinking-bubble/index.ts's header), and
// `session_start` hasn't been proven live the way `message_received` has
// across two sibling plugins. So: track "have we greeted this session" in
// a plain in-memory Set keyed by sessionKey, and send the menu on the first
// message_received for a session not yet in it. Same
// single-process/single-VPS assumption website/index.ts already documents
// for its own sessionKey fallback -- resets on gateway restart, which just
// means the menu resends once more; harmless.
//
// tg()/extractChatId/extractProvider/extractSessionKey below are
// intentionally duplicated from thinking-bubble/index.ts and
// website/index.ts rather than shared -- each plugin ships as an
// independent workspace-extension directory (see setup.sh's docker cp
// steps), so importing across them would mean inventing shared-file
// plumbing just to avoid ~30 lines of duplication. Not worth it.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

/** 2-per-row grid, matching FarmOps' own keyboard shape. `/website` and
 * `/new` lead (this product's headline feature, then the most common
 * reset action); TTS gets both toggles plus a status button, not just a
 * read-only check, since the product owner is actively exploring that
 * feature; `/usage cost` and `/status` close out discovery, `/help` is
 * the fallback. Deliberately `/usage cost`, not bare `/usage` -- per
 * docs/concepts/usage-tracking.md, bare `/usage` CYCLES the per-response
 * footer mode (off -> tokens -> full -> off) on every invocation, so a
 * button sending it would do something different each tap depending on
 * hidden prior state. `/usage cost` is a stable, idempotent local cost
 * summary -- the actual "check my spend" behavior a BYOK customer wants
 * from a button, not a footer-verbosity toggle. */
const KEYBOARD_ROWS: { text: string }[][] = [
  [{ text: "/website" }, { text: "/new" }],
  [{ text: "/tts on" }, { text: "/tts off" }],
  [{ text: "/tts status" }, { text: "/usage cost" }],
  [{ text: "/status" }, { text: "/help" }],
];

/** `resize_keyboard` shrinks the keyboard to fit its buttons instead of
 * full-size default rows. `is_persistent` and `one_time_keyboard` are
 * deliberately omitted -- confirmed in FarmOps' own bridges that setting
 * `is_persistent` forces the keyboard permanently visible and removes
 * Telegram's own show/hide toggle icon, which is exactly the "toggle
 * button in the text input area" behavior the product ask wants
 * preserved. Sent as a plain nested object (not a JSON.stringify'd
 * string) since this goes out over an `application/json` POST body, where
 * Telegram's Bot API accepts `reply_markup` as a native nested object;
 * stringifying is only required for multipart/form-encoded requests. */
const QUICK_MENU_KEYBOARD = { keyboard: KEYBOARD_ROWS, resize_keyboard: true };

const QUICK_MENU_INTRO =
  "Quick menu ready ⬇️\n\n" +
  "Tap the keyboard icon next to the text box any time to bring these back up. " +
  "Each button sends the exact command shown -- same as typing it yourself.";

/** sessionKey -> already greeted. Bounded the same way website/index.ts
 * bounds sessionKeyByToolCallId: entries are never removed except by this
 * cap, so a long-running gateway that accumulates many distinct sessions
 * can't grow this unboundedly. */
const MAX_TRACKED_SESSIONS = 200;
const greetedSessionKeys = new Set<string>();

async function tg(botToken: string, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as { ok?: boolean; description?: string };
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

export default definePluginEntry({
  id: "quick-menu",
  name: "Quick Menu",
  description: "Sends a persistent Telegram custom keyboard of curated commands once per session.",
  register(api) {
    api.on(
      "message_received",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.QUICK_MENU_BOT_TOKEN;
        if (!botToken) return;

        const provider = extractProvider(event as Record<string, unknown>, ctx);
        const chatId = extractChatId(event as Record<string, unknown>, ctx);
        const sessionKey = extractSessionKey(event as Record<string, unknown>, ctx);

        if (provider !== "telegram" || !chatId || !sessionKey) return;
        if (greetedSessionKeys.has(sessionKey)) return;

        // Claim now, before any await, so a duplicate/retried event for the
        // same session can't double-send.
        if (greetedSessionKeys.size >= MAX_TRACKED_SESSIONS) {
          const oldest = greetedSessionKeys.values().next().value;
          if (oldest !== undefined) greetedSessionKeys.delete(oldest);
        }
        greetedSessionKeys.add(sessionKey);

        try {
          await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text: QUICK_MENU_INTRO,
            reply_markup: QUICK_MENU_KEYBOARD,
          });
        } catch (err) {
          console.error(
            "[quick-menu] failed to send quick menu:",
            err instanceof Error ? err.message : String(err),
          );
        }
      },
      { priority: 10 },
    );
  },
});

// Quick Menu plugin
//
// Defines the persistent Telegram custom keyboard (Bot API
// `ReplyKeyboardMarkup` -- the grid revealed by the toggle button next to
// the text input, distinct from the native "/" autocomplete list
// `setMyCommands` already populates) of this product's most useful
// commands, and attaches it via a standalone message this plugin sends
// directly -- never via a message something else deletes or edits.
//
// --- History: two prior designs, both wrong, both real device failures ---
//
// v1 sent a dedicated "Quick menu ready" message on the first
// message_received of a session, tracked in-memory "once per session".
// Rob (product owner), 08-18, with a screenshot: that message re-appeared
// right after a real command reply (e.g. a quick-menu button sending
// `/usage cost`) because the "new session" tracking didn't exclude
// slash-command messages. The ask was "remove it entirely, permanently",
// not "de-duplicate it" -- after a couple of uses the button grid is
// self-explanatory.
//
// v2 attached the keyboard to thinking-bubble's placeholder message (first
// as a plain send-then-delete placeholder, then as a "permanent carrier"
// placeholder that got edited-in-place instead of deleted). Both sub-attempts
// coupled the keyboard's lifecycle to the placeholder's lifecycle, and Rob's
// live testing (08-18) showed the keyboard still wasn't persisting even with
// the edit-in-place version. That's when this got checked against FarmOps
// (`ai-farm/scripts/bridge_common.py` clear_chat, ~376-413), which hit this
// EXACT bug on 2026-07-25 and documented the real, confirmed mechanism in
// its own code comments: "Deleting older messages that originally carried
// the keyboard was found to drop it from the client entirely (Rob,
// 07-25), so it has to be re-asserted here every time." FarmOps' own fix
// is not "pick a message that's deleted less often" -- it's "never let the
// keyboard-carrying message be deletable or editable AT ALL". Every FarmOps
// attach site (/start, /help, /new, clear_chat's confirmation) is a plain
// `send(..., reply_markup=KEYBOARD)` on a message that is sent once and
// never touched again. Its placeholder/"thinking" sends (`TG.send_dim`)
// never carry reply_markup at all -- clean separation between the
// keyboard's lifecycle and the placeholder's lifecycle, not just "a more
// durable placeholder".
//
// --- This design (v3): a real, permanent, standalone message ---
//
// OpenClaw's own reply-delivery path has no passthrough for a custom
// ReplyKeyboardMarkup (dist/types-*.d.ts's ReplyPayload has no
// reply_markup field; its only escape hatch, channelData?.telegram, only
// ever produces an inline_keyboard via buildInlineKeyboard -- a different,
// incompatible keyboard type -- confirmed by tracing the compiled send
// path, see thinking-bubble/index.ts's header for the full trace). So this
// plugin sends its OWN small message directly via the Telegram Bot API
// (the tg() helper below, same direct-API approach FarmOps' own bridge
// uses) riding alongside OpenClaw's natural reply, not replacing it.
//
// Trigger points, matching FarmOps' scope exactly: /start and /new. Both
// are confirmed (live testing + reading OpenClaw's own compiled command
// registry, dist/commands-registry.data-*.js) to be real, distinct request
// events this plugin's message_received hook actually observes:
//   - /start has NO entry in the native command registry at all (no
//     key: "start"/nativeName: "start" anywhere in commands-registry.data),
//     so it falls through to the normal agent-turn dispatch path -- a real,
//     personalized, LLM-generated welcome, not a template.
//   - /new DOES have a native registry entry (key: "new", nativeName:
//     "new", textAlias: "/new", tier: "essential") -- it's a fast built-in
//     that resolves instantly, same category as /help and /status, and
//     never reaches reply_payload_sending.
// Both differ in how OpenClaw itself replies, but message_received fires
// for both regardless (it's the raw-inbound hook, upstream of native-vs-
// agent-turn dispatch) -- so hooking message_received here, matching
// content against /start or /new, and sending our own message immediately
// works uniformly for both without needing to correlate against
// reply_payload_sending (which /new never fires) or depend on any other
// message's delivery timing at all. That's the whole point: this plugin's
// send has zero dependency on any other message's lifecycle.
//
// No "already sent to this chat" durable tracking, matching FarmOps
// exactly -- grepping FarmOps' bridge for any such gate turned up nothing;
// it just unconditionally re-sends reply_markup on every /start, /help,
// /new, relying on Telegram's own client-side keyboard caching (only
// refreshed when a message carrying reply_markup arrives). Rob has not
// objected to /start or /new themselves carrying the keyboard message --
// only to it appearing unprompted after ordinary chat, which this design
// no longer does since only /start/-/new trigger it.
//
// KEYBOARD_ROWS/QUICK_MENU_KEYBOARD are the canonical, curated definition
// of the button grid -- not duplicated elsewhere anymore now that
// thinking-bubble's placeholder has gone back to carrying zero keyboard
// logic (see that file's header for its own, much shorter, note about this).

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
export const KEYBOARD_ROWS: { text: string }[][] = [
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
export const QUICK_MENU_KEYBOARD = { keyboard: KEYBOARD_ROWS, resize_keyboard: true };

/** Matches bare "/start", a deep-link payload ("/start payload"), and the
 * "/start@BotName" form Telegram uses in group chats. */
function isStartCommand(content: string): boolean {
  return /^\/start(@\w+)?(\s|$)/.test(content);
}

/** Matches bare "/new" and the "/new@BotName" group-chat form. */
function isNewCommand(content: string): boolean {
  return /^\/new(@\w+)?(\s|$)/.test(content);
}

const START_KEYBOARD_TEXT = "👋 Quick menu ready -- tap the icon beside the message box anytime.";
const NEW_KEYBOARD_TEXT = "🆕 Fresh session -- quick menu ready.";

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

export default definePluginEntry({
  id: "quick-menu",
  name: "Quick Menu",
  description: "Sends the curated Telegram quick-menu keyboard as a standalone, permanent message on /start and /new -- matching FarmOps' proven pattern of never attaching reply_markup to a message that gets deleted or edited.",
  register(api) {
    api.on(
      "message_received",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.QUICK_MENU_BOT_TOKEN;
        if (!botToken) return;

        const provider = extractProvider(event as Record<string, unknown>, ctx);
        const chatId = extractChatId(event as Record<string, unknown>, ctx);
        if (provider !== "telegram" || !chatId) return;

        const content = typeof (event as { content?: unknown }).content === "string"
          ? (event as { content: string }).content.trim()
          : "";

        let text: string | undefined;
        if (isStartCommand(content)) text = START_KEYBOARD_TEXT;
        else if (isNewCommand(content)) text = NEW_KEYBOARD_TEXT;
        if (!text) return;

        try {
          await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text,
            reply_markup: QUICK_MENU_KEYBOARD,
          });
        } catch (err) {
          console.error("[quick-menu] failed to send keyboard-carrier message:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );
  },
});

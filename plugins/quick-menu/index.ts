// Quick Menu plugin
//
// Defines the persistent Telegram custom keyboard (Bot API
// `ReplyKeyboardMarkup` -- the grid revealed by the toggle button next to
// the text input, distinct from the native "/" autocomplete list
// `setMyCommands` already populates) of this product's most useful
// commands.
//
// --- No standalone announcement message (but see the correction below) ---
//
// This plugin used to send a dedicated "Quick menu ready" message on the
// first message_received of a session to attach the keyboard, tracked
// in-memory "once per session". Rob (product owner), 08-18, with a
// screenshot: that message re-appeared right after a real command reply
// (e.g. a quick-menu button sending `/usage cost`) because the "new
// session" tracking didn't exclude slash-command messages -- the same
// category of gap thinking-bubble/index.ts's header documents fixing for
// its own placeholder. But the ask wasn't "de-duplicate it", it was
// "remove it entirely, permanently": after a couple of uses the button
// grid is self-explanatory, and repeating the explanation is just noise.
//
// A follow-up version of this plugin then attached QUICK_MENU_KEYBOARD to
// thinking-bubble's placeholder message on the theory that a
// `ReplyKeyboardMarkup` is chat-level client state that survives deletion
// of the message that carried it -- so it was safe to attach to a
// send-then-delete placeholder. That theory came from an unverified
// WebSearch, was never checked against a real device, and Rob's own real
// device testing (08-18) directly contradicted it: the keyboard vanished
// after the placeholder was deleted. Telegram's own docs don't confirm
// the "survives deletion" claim either way, and no real developer report
// of this specific interaction (attach, then delete that exact message)
// turned up anywhere searched -- see thinking-bubble/index.ts's header for
// the full writeup and the actual fix (a never-deleted "permanent
// carrier" message, tracked durably per chat, sent once ever). Do not
// resurrect the "any deleted message is a safe carrier" assumption here.
//
// This plugin still ships and loads (openclaw.plugin.json, setup.sh) as
// the canonical, curated definition of the button grid below --
// duplicated into thinking-bubble/index.ts rather than imported, matching
// this codebase's established pattern of duplicating small pieces (tg(),
// extractChatId, ...) across independent plugin workspace-extension
// directories instead of inventing cross-plugin import plumbing.

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

export default definePluginEntry({
  id: "quick-menu",
  name: "Quick Menu",
  description: "Defines the curated Telegram quick-menu keyboard; attached via thinking-bubble's placeholder send, not a standalone message.",
  register() {
    // No hooks: this plugin only defines the keyboard content above. The
    // Telegram send that actually carries it to the client happens in
    // thinking-bubble/index.ts -- see this file's header comment for why.
  },
});

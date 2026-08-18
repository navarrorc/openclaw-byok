// Location plugin
//
// Matches Nelita's location-sharing behavior (nelita_bridge.py, read-only
// reference, not touched): a "📍 Share Location" keyboard button (defined
// in plugins/quick-menu/index.ts's KEYBOARD_ROWS -- this plugin doesn't own
// the keyboard) lets the user hand over their coordinates once, this plugin
// remembers them for a few hours, and any turn asked something location-
// dependent (weather, nearby places, travel time) within that window gets
// a short context line about where the user is. Not a weather feature by
// itself -- a "does the model know where the user is" primitive.
//
// --- What plugins can actually see here: verified against the compiled
//     bundle, not assumed from docs (same discipline as everything else
//     touched in this repo today) ---
//
// message_received's shipped event type (PluginHookMessageReceivedEvent,
// dist/hook-types-*.d.ts) has no lat/lon/location field, and tracing the
// exact function that builds that event (toPluginMessageReceivedEvent,
// dist/message-hook-mappers-*.js) confirms its `metadata` object is a fixed,
// enumerated list of fields that doesn't include one either. Telegram's own
// channel plugin DOES parse message.location/message.venue into a
// structured object (extractTelegramLocation, dist/sent-message-cache-*.js)
// -- but that structured data only ever feeds the model-facing PROMPT
// context (docs/channels/location.md's LocationLat/LocationLon/... fields),
// never the plugin hook payload. The only trace of a location share a
// plugin can see at all is the flattened text OpenClaw's Telegram channel
// renders into `content` (formatLocationText, dist/channel-inbound-*.js):
//   "📍 <lat>, <lon>" (+" ±<n>m" if accuracy is known) for a pin/venue share
//   "🛰 Live location: <lat>, <lon>" (+accuracy) for a live share
// So this plugin regex-parses that text. This is a real, structural
// limitation of this OpenClaw version, not a design choice -- there is no
// structured location surface for plugin hooks to read.
//
// Telegram's Live Location repeat ticks (position updates while a live
// share is active) arrive as `edited_message` Telegram updates, not
// `message` updates. Confirmed by reading the compiled Telegram ingress
// (dist/telegram-ingress-spool-*.js): `bot.on("edited_message", ...)`
// routes only through recordEditedMessageForReplyChain (a reply-chain
// cache), which never calls into the inbound-hook pipeline that produces
// message_received -- unlike `bot.on("message", ...)`, which does. So
// message_received never fires again for a live-location refresh tick:
// every location match this plugin ever sees is a first share, never a
// repeat. That's convenient (no is_edit disambiguation needed, unlike
// Nelita's Python bridge, which polls raw Telegram updates directly and has
// to filter edited_message ticks itself) but it's also a real, honest gap:
// unlike Nelita, an active Live Location share's position here goes stale
// after LOCATION_FRESH_MS like an ordinary one-shot pin -- it does NOT keep
// refreshing silently in the background, because OpenClaw's plugin surface
// has nothing to refresh it from.
//
// message_received is observation-only (handler returns void -- confirmed
// from its exact type, dist/hook-types-*.d.ts) -- it cannot stop the normal
// agent turn from also seeing and replying to the same "📍 <lat>, <lon>"
// text. Same real, visible degradation plugins/website/index.ts already
// flags for its own claimed-follow-up path: sharing a location may produce
// TWO replies (this plugin's short ack, and whatever the model naturally
// says back to a raw coordinate string) until/unless OpenClaw adds a way to
// claim an inbound message outright.
//
// Storage: in-memory Map, matching this repo's current, deliberate
// convention (as of commit 300ff41 -- see quick-menu/thinking-bubble's own
// history in their headers) of NOT persisting plugin state under
// /data/plugin-state/... anymore; that durable-file approach was tried
// earlier today for an unrelated problem (the keyboard-carrier message) and
// abandoned in favor of a simpler design. A 6h freshness window is short
// enough that losing it on a container restart/redeploy is a minor,
// acceptable degradation -- consistent with plugins/website/index.ts's own
// sitesBySessionKey/awaitingDescriptionBySessionKey being in-memory-only
// despite representing "real" state too.
//
// Context injection: before_prompt_build (dist/hook-runner-global-*.js's
// runBeforePromptBuild -- genuinely dispatched, not just documented,
// confirmed by reading the hook runner itself, not just hooks.md) is the
// hook PROMPT_INJECTION_HOOK_NAMES lists for exactly this. Its ctx argument
// (PluginHookAgentContext) carries `sessionKey`, the same correlation key
// message_received's event carries, used here to look up the right chat's
// stored location. Whether this hook actually fires and actually reaches
// the model was verified live against the test box -- see the repo's
// verification notes for what was actually observed, not assumed.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const LOCATION_FRESH_MS = 6 * 60 * 60 * 1000; // 6h, matching Nelita's LOCATION_FRESH_SECS default

/** Matches formatLocationText's exact output (dist/channel-inbound-*.js) --
 * the only location data visible to a plugin hook in this OpenClaw version.
 * See header comment. */
// The bare 📍 alternative can, in principle, match a user manually typing/
// pasting two decimal numbers next to a pin emoji -- there's no structured
// signal to disambiguate that from a real share (see header comment for
// why). Accepted false-positive risk given the platform's real constraints;
// worst case is a stale/wrong location context for one turn.
const LOCATION_TEXT_RE = /(🛰 Live location:|📍)\s*(-?\d+\.\d+),\s*(-?\d+\.\d+)/;

type StoredLocation = { lat: number; lon: number; ts: number; isLive: boolean };

/** sessionKey -> last known location. In-memory only -- see header comment. */
const locationBySessionKey = new Map<string, StoredLocation>();

function parseLocationText(content: string): { lat: number; lon: number; isLive: boolean } | undefined {
  const m = content.match(LOCATION_TEXT_RE);
  if (!m) return undefined;
  const lat = Number(m[2]);
  const lon = Number(m[3]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return undefined;
  return { lat, lon, isLive: m[1].startsWith("🛰") };
}

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

/** Same defensive fan-out pattern as plugins/quick-menu/index.ts and
 * plugins/website/index.ts's own extractChatId -- the real runtime event
 * carries more candidate fields than its shipped .d.ts type does. */
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

/** Fresh copy for this product -- not Nelita's wording. Doesn't promise a
 * live-tracking duration (unlike Nelita) since this plugin never sees
 * Live Location's repeat ticks -- see header comment. */
const LOCATION_ACK_TEXT =
  "📍 Got your location. I'll use it for anything nearby -- weather, places, travel time -- for the next few hours.";

export default definePluginEntry({
  id: "location",
  name: "Location",
  description:
    "Lets the user share their Telegram location via the quick-menu button and injects it as short-lived context into subsequent turns, matching Nelita's location-sharing behavior.",
  register(api) {
    // Lazy eviction inside before_prompt_build only evicts a session's entry
    // when that session actually gets another turn -- a chat that shares a
    // location once and never turns again would otherwise leak forever.
    // Same sweep pattern as plugins/website/index.ts's
    // awaitingDescriptionBySessionKey for the identical reason. unref() so
    // it can't keep the process alive on its own.
    setInterval(() => {
      const now = Date.now();
      for (const [sessionKey, loc] of locationBySessionKey) {
        if (now - loc.ts > LOCATION_FRESH_MS) locationBySessionKey.delete(sessionKey);
      }
    }, 60_000).unref();

    api.on(
      "message_received",
      async (event, ctx) => {
        const e = (event ?? {}) as Record<string, unknown>;
        const c = (ctx ?? {}) as Record<string, unknown>;

        const provider = extractProvider(e, c);
        if (provider !== "telegram") return;

        const content = typeof e.content === "string" ? e.content : "";
        const loc = parseLocationText(content);
        if (!loc) return;

        const sessionKey = (typeof e.sessionKey === "string" && e.sessionKey) || (c as { sessionKey?: string }).sessionKey || "global";
        locationBySessionKey.set(sessionKey, { lat: loc.lat, lon: loc.lon, ts: Date.now(), isLive: loc.isLive });

        const botToken = process.env.LOCATION_BOT_TOKEN;
        const chatId = extractChatId(e, c);
        if (!botToken || !chatId) return;

        try {
          await tg(botToken, "sendMessage", { chat_id: chatId, text: LOCATION_ACK_TEXT });
        } catch (err) {
          console.error("[location] failed to send location ack:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );

    api.on("before_prompt_build", async (_event, ctx) => {
      const sessionKey = (ctx as { sessionKey?: string } | undefined)?.sessionKey ?? "global";
      const loc = locationBySessionKey.get(sessionKey);
      if (!loc) return;

      const age = Date.now() - loc.ts;
      if (age > LOCATION_FRESH_MS) {
        locationBySessionKey.delete(sessionKey);
        return;
      }

      const minutes = Math.max(0, Math.round(age / 60000));
      const when = minutes < 1 ? "just now" : `${minutes} min ago`;
      return {
        prependContext:
          `[location: the user's last shared position is latitude ${loc.lat.toFixed(4)}, longitude ` +
          `${loc.lon.toFixed(4)} (shared ${when}). Use it only if the request is location-dependent ` +
          `(weather, nearby places, travel time); ignore it otherwise. Never read raw coordinates back to ` +
          `the user -- name the place if you can determine one, otherwise just use it silently.]\n\n`,
      };
    });
  },
});

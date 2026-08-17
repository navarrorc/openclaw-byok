# Per-Customer Isolation & Handoff Model

DRAFT — decision pass, not implementation. Follows the security model Rob picked
08-17 ("Option A — we don't have access": true per-customer VPS, we provision then
step back, no retained SSH/Coolify access after handoff).

## The tension this document has to resolve

Rob's own framing has two halves that don't automatically fit together:

> "We would still be the admin and possibly guide them through the process, like
> you did in Coolify... I would then check it on my end to see if it works...
> still manage the VPS for them" — but also — "they shouldn't need to share their
> credentials with us... we don't have access to it."

"We manage it" and "we don't have access" are only compatible if "manage" means
something narrower than standing admin rights. The live case study from today's
own session shows the shape of that narrower thing: Rob had **zero** prior SSH
access to his own sandbox VPS from this machine. Getting access required (1) Rob
adding a public key via Coolify's UI — which alone was *not* enough because
Coolify's own trust didn't propagate to the new key — so (2) Rob opened Coolify's
**own web terminal** (which already had trusted access) and ran one command we
handed him (`echo "..." >> ~/.ssh/authorized_keys`), and only then did (3) direct
SSH work.

That's a real, working instance of "guide someone through a command via a channel
we don't otherwise have access through." It generalizes to three places in this
design: provisioning (§1), verification (§2), and ongoing support (§3) all reuse
the same shape — Rob never holds standing credentials; the customer runs a
command we give them, through a channel only they control.

---

## 1. Provisioning — how does a customer's VPS come to exist?

### Option A — customer's own cloud account, we hand them a script

Customer creates their own DigitalOcean/Hetzner/Linode account (or uses an
existing one) and a droplet, then pastes a single cloud-init or shell script we
give them — installs Docker, Coolify or a bare docker-compose stack, pulls the
OpenClaw image, prompts for their LLM key, done. Mirrors the Coolify-terminal
pattern exactly: we hand over a command, they run it in a channel we never touch.

- **Pros:** clean from the very first second — there is no moment where Rob's
  account holds the box, so there's nothing to transfer or revoke later. Zero
  cloud-provider lock-in (works identically on any VPS host). Zero cost to us
  (customer pays their own hosting bill directly). Directly reuses a pattern
  already proven working today.
- **Cons:** customer needs to be willing to create a cloud account and paste a
  script into a terminal — real friction for a non-technical buyer, and a wrong
  paste (extra key, wrong region, closed firewall) is now *their* mistake to
  debug, with us only able to help via whatever remote-support channel §3 ends
  up being. Onboarding quality varies with customer comfort level.

### Option B — we provision under our account, then transfer

We spin up the droplet under our own cloud account (faster iteration, full
control while we get it right), then hand ownership/billing to the customer as a
discrete step.

- **Pros:** during setup, we have real, fast, native access — no guided-terminal
  choreography, no risk of the customer fat-fingering a step. Good for the
  Standard/Premium tiers where more gets installed (dashboards, n8n,
  Cloudflare tunnel, telephony) and there's more that could go wrong on a first
  build.
- **Cons — this is a real landmine, not just extra steps:** neither DigitalOcean
  nor Hetzner supports moving a droplet's ownership between two separate
  top-level accounts. The only real path is snapshot-and-redeploy: image the
  finished droplet, get that image into the customer's account (DO only shares
  custom images between members of the *same* DO Team — not across unrelated
  accounts — so this usually means exporting the image and having the customer
  re-upload/redeploy it), and the redeployed droplet gets a **new IP address**,
  which breaks DNS, the Cloudflare tunnel config, and anything else that was
  pointed at the old one. That's a second setup pass, not a clean handoff. This
  option sounds simpler than it is.

### Option C — 1-click cloud marketplace image

A prebuilt DigitalOcean Marketplace (or equivalent) image the customer deploys
themselves with zero copy-paste — pick the image, click deploy, done.

- **Pros:** best first-run UX of the three, and it's really Option A with the
  copy-paste step removed — the customer still deploys into their own account
  from minute one, so it doesn't reopen the transfer problem in §B.
- **Cons:** DigitalOcean's Marketplace is a **public** listing — visible to and
  usable by any DO customer, not just ours — plus a vendor review/vetting
  process with real lead time, and an ongoing obligation to keep the listed
  image current with DO's bar. That's a real commitment for what's currently a
  one-person product. A private middle ground exists (a `doctl`/Terraform
  one-liner we author and host ourselves, run from the customer's own CLI) —
  friendlier than pasting a shell script, without the public-listing exposure —
  worth considering as a v2 UX polish on top of Option A, not a replacement for
  it.

**Recommendation for provisioning: Option A now, with a private one-liner
(doctl/Terraform, not a public Marketplace listing) as a later UX upgrade, not a
different model.** It's the only one of the three that has no moment where
ownership needs to move, which is exactly the property the "we don't have
access" pitch depends on. Option B trades a smoother *build* experience for a
genuinely awkward *handoff*, working against the one decision Rob already made
deliberately. Flagging this as something to react to at the checkpoint — not
silently deciding it.

---

## 2. Verification without access

Rob's own words: "I would then check it on my end to see if it works." That
needs *some* signal that reaches Rob without shell/Coolify access to the box.
Ranked by how much they prove vs. how much access they imply:

- **One-time test message (recommended primary signal).** The setup script's
  last step has the freshly-deployed OpenClaw instance send one message —
  through the customer's own configured channel (their Telegram bot, or a temp
  one used only for setup) — into a Rob-controlled inbox, e.g. `"CONFIRMED —
  <customer-id> — <timestamp> — provider: <google|openai|anthropic>"`. This is
  literally today's own smoke test (`"Reply with the single word CONFIRMED"` →
  real Gemini round-trip), generalized. Costs nothing extra to build — it's a
  natural last line of the same script that does the provisioning. Proves the
  full chain (box up → container healthy → BYOK key wired → real LLM call)
  in one signal, and then that channel goes quiet — it isn't a standing access
  path.
- **Auth-gated health endpoint (optional, for later "is it still up" checks).**
  A `/health` route on the deployed instance, protected by a token generated at
  provisioning time, returning only `{"status":"ok","version":"..."}` — no chat
  content, no config, no customer data. Worth being explicit that this *is* a
  standing access path, even though a narrow, read-only, boolean one — Rob
  should decide at the checkpoint whether that counts as "access" for the
  purposes of the pitch, or whether it's fine because it can't do anything.
  This is also the natural seed of the §3 Option 3 remote-management agent, so
  building it once could serve both purposes.
- **Customer self-report ("it worked, here's a screenshot").** Lowest cost,
  weakest signal — no independent proof, pure trust. Fine as a fallback, not a
  primary mechanism for a security-forward pitch.

---

## 3. Ongoing support & updates post-handoff — the hard one

This is where "we manage it" and "we don't have access" actually collide. Three
real options, with honest tradeoffs; recommendation at the end.

### Option 1 — fully self-managed

Baked into the base image: a systemd timer/cron doing `docker compose pull &&
up -d` on a schedule, plus a local watchdog that restarts a crashed container.
Zero access, ever, by design — genuinely nobody but the customer can reach the
box after handoff.

- **Pros:** simplest to build (a cron entry and a small shell watchdog, no new
  service to secure), the purest possible version of the "we truly cannot
  touch your box" claim, zero ongoing ops load on Rob no matter how many
  customers sign up.
- **Cons:** when something breaks in a way auto-restart can't fix — bad config,
  full disk, a botched manual edit, a Docker daemon wedge — the customer is
  simply stuck, with nothing more than "reboot it and hope." That's a weak
  support story for a *paid* product, and it directly contradicts what Rob
  described wanting to build ("I would then check it on my end... still manage
  the VPS for them"). Feels safe to ship as-is only for the cheapest tier.

### Option 2 — time-boxed re-invite (customer-initiated access window)

Generalizes today's own working pattern. The box ships with a documented,
one-command "invite support" action — e.g. paste one line into the box's own
terminal (SSH, or a Coolify-style web terminal if one's installed) that appends
Rob's current public key to `authorized_keys`, **with an auto-expiry baked into
the same command** (an `at now + 2 hours` job, or a short-lived line stripped by
a timer) so revocation doesn't depend on the customer remembering. Customer
pastes it only when they've asked for help; Rob has full shell for that window;
then it's gone on its own.

- **Pros:** reuses a mechanism already proven today rather than inventing new
  software. Full, unrestricted shell when it's genuinely needed — no narrow
  verb list to bump into during a real emergency. Access exists strictly in
  windows the customer explicitly opened, which is an honest, verifiable
  version of "we don't have standing access." Matches what Rob actually
  described almost exactly (guide-through-a-command, like the Coolify
  terminal). Cheap to build: mostly a runbook + one small helper script, not a
  new always-on service.
- **Cons:** it's full root during the window, so the pitch is "we technically
  *could* do anything, only during a window you open," not "we technically
  *can't* do arbitrary things" — a real, honest, but less strong claim than
  Option 3. Requires the customer to be present to grant access, so it can't
  self-heal a 3am outage unattended — Option 1's auto-restart still matters as
  a first line of defense underneath this.

### Option 3 — scoped remote-management agent

A small always-on service baked into the base image, exposing a fixed, narrow
API (restart container, pull + redeploy latest image, tail last N log lines,
report health) — authenticated with a token the **customer** generates and can
rotate/revoke at will, not one Rob holds by default.

- **Pros:** the strongest "we technically can't do arbitrary things" claim of
  the three, since the verb set is fixed and auditable. Doesn't require the
  customer to be present or to act first — could plug into a dashboard that
  proactively catches the common failure modes (crashed container, stale
  image) across a whole fleet of customers later.
- **Cons:** real, ongoing build and security cost — this is new software that
  itself needs to be kept patched and secure on every customer box, which
  circles back to the same "how do we update something on a box we don't
  control" question one level up (it can be designed to self-update, but that's
  exactly the kind of thing that needs to be gotten right, not hand-waved).
  The fixed verb list means the actual rare emergency — disk full, daemon
  wedged, a customer's own bad edit — still can't be fixed through it, so
  Option 2 remains necessary anyway as the escape hatch. A second permanent
  attack surface on every box is a real ongoing liability, not a one-time cost.

### Recommendation

**Stack Option 1 + Option 2 for v1; treat Option 3 as a later upgrade, not a
launch requirement.** Reasoning: Option 1's auto-restart/auto-update removes
most of the reasons anyone would ever need to ask for help at all, which is the
right default given the security pitch. Option 2 is the actual answer to "what
happens when that's not enough" — it's cheap (no new software, just a
documented runbook and a one-line expiring-key script), it's already proven
today, and it matches what Rob described wanting almost exactly. Option 3 is a
legitimate longer-term investment once there's a real fleet where re-invite
windows start being an operational bottleneck (many customers needing help at
once, or wanting to offer help *before* the customer notices something's
wrong) — building it now, before there's a second customer, is premature scope
for a product that's still proving out its first pilot.

This is a recommendation, not a decision — the checkpoint asks Rob to pick one
of these three (or a different mix) explicitly.

---

## 4. What this means for the current sandbox

The sandbox deployed today (Coolify project `OpenClaw-Product-POC`, smoke-tested
with a real Gemini round-trip) lives on **Rob's own shared VPS**, alongside his
existing Personal and N8N Coolify projects. It proves the BYOK plumbing works
(env-var key → container → real LLM call) — it does **not** demonstrate the
isolation model at all, because Rob already has, and always will have, full
standing access to that box. Calling it a "pilot" of Option A would overstate
what it's actually shown.

A true first customer-isolated pilot needs, at minimum:

- A genuinely separate VPS under an account Rob does **not** administer day to
  day — could be a second personal cloud account standing in as "the customer"
  for the test, or a real first willing customer — provisioned via whichever
  §1 path gets picked.
- Rob actually exercising §2's verification mechanism as the *only* signal he
  uses to confirm it worked — no peeking via a Coolify dashboard he happens to
  still have open, since that would silently reintroduce the access this whole
  design is trying to remove.
- Rob actually walking the chosen §3 support mechanism at least once for real —
  e.g. deliberately breaking something on the test box and using the
  time-boxed re-invite flow to fix it — before this model gets called
  validated rather than just designed.

None of that is scoped for this pass. This document is the design; standing up
that pilot is the next, separately-scoped job once Rob has picked a direction
below.

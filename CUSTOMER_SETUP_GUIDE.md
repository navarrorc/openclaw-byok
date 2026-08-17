# Setting up your OpenClaw sandbox

This walks you through getting your own private OpenClaw assistant running
on a server only you control. It takes about 15 minutes, no coding
experience needed. You'll copy and paste a few things into a terminal.

**What you're building:** a small cloud server (sometimes called a
"droplet" or a "VPS") that runs OpenClaw using your own AI provider
account (Gemini, OpenAI, or Anthropic). You pay your cloud host directly
for the server, and your AI provider directly for usage. We never see or
hold either of those accounts. We hand you a setup script, you run it,
and from that moment the box is yours.

---

## Step 1: Create a cloud server

Pick one of these (any works fine, DigitalOcean is the simplest for
first-timers):

- **DigitalOcean**: [digitalocean.com](https://digitalocean.com) → "Create" → "Droplets"
- **Hetzner**: [hetzner.com](https://hetzner.com) → "Add Server"
- **Linode/Akamai**: [linode.com](https://linode.com) → "Create Linode"

When creating it, choose:

- **Image / OS:** Ubuntu 26.04 (LTS). 24.04 or 22.04 also work fine if
  that's what your host offers.
- **Size:** the cheapest "Basic"/shared-CPU plan with at least **2 GB
  RAM** is enough for a single assistant (roughly $12 to $18/month on
  most hosts).
- **Authentication:** if it asks for an SSH key and you don't have one,
  it's fine to use a password instead. You'll switch to key-only access
  as part of setup.
- **Region:** wherever's closest to you.

Once it's created, you'll be given a public **IP address** (four numbers
like `104.xxx.xxx.xxx`). You'll need that in the next step.

## Step 2: Connect to your server

- **Mac/Linux:** open the Terminal app
- **Windows:** open PowerShell

Then run (replace the IP with yours):

```
ssh root@104.xxx.xxx.xxx
```

A couple of things will happen the first time you connect. Nothing here
is a problem, it's just what a brand-new server does the very first time
anyone logs in:

1. **A one-time trust prompt.** You'll see a short message asking if you
   trust this server. This is completely normal for any server the very
   first time you connect to it. Just type `yes` and press Enter.
2. **Your starting password.** Enter the password your cloud host gave
   you when the server was created (check your email or the server's page
   in your host's dashboard). If you set up an SSH key instead when
   creating the server, you won't see a password prompt at all, just skip
   ahead to Step 3.
3. **A password reset.** Many hosts ask you to pick a new password the
   moment you first log in, as a security precaution. If prompted, type
   your current password once more, then type a new password twice. Pick
   something you'll remember.
4. **A quick reconnect.** After you set the new password, you'll be
   dropped back out to your own computer. That's expected, not an error.
   Just log in again the same way, using your new password this time:
   ```
   ssh root@104.xxx.xxx.xxx
   ```
   This time you'll land right in.

## Step 3: Run the setup script

Once connected, paste this:

```
curl -fsSL https://raw.githubusercontent.com/navarrorc/openclaw-byok/v1.0.0/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/navarrorc/openclaw-byok/v1.0.0/install-watchdog.sh -o install-watchdog.sh
curl -fsSL https://raw.githubusercontent.com/navarrorc/openclaw-byok/v1.0.0/support-access.sh -o support-access.sh
chmod +x setup.sh install-watchdog.sh support-access.sh
./setup.sh
```

The script will ask you a few questions:

1. **Your SSH public key** (only if one wasn't already set up when you
   created the droplet). This makes sure you can still log back in after
   the script locks down password logins for security. If you don't know
   what that is or don't have one yet, here's how to get one:

   **What it is, in plain terms:** an SSH key is a pair of files that let
   you log in without typing a password. One half stays secret on your
   own computer (never share this one). The other half, the "public" one,
   is safe to hand out. Pasting your public key here lets your assistant
   recognize your computer from now on.

   **If you already have one:** you'll usually find it at
   `~/.ssh/id_ed25519.pub` (Mac/Linux) or `C:\Users\<you>\.ssh\id_ed25519.pub`
   (Windows). Open that file, copy everything inside (it's one long line
   starting with `ssh-ed25519`), and paste it when the script asks.

   **If you don't have one, create one first:**

   - **Mac/Linux:** in a Terminal window, run:
     ```
     ssh-keygen -t ed25519
     ```
     Press Enter at every question to accept the defaults (a passphrase
     is optional, you can leave it blank). Then show your public key with:
     ```
     cat ~/.ssh/id_ed25519.pub
     ```
   - **Windows:** in PowerShell, run:
     ```
     ssh-keygen -t ed25519
     ```
     (PowerShell already has this built in, no download needed.) Press
     Enter at every question. Then show your public key with:
     ```
     type $env:USERPROFILE\.ssh\id_ed25519.pub
     ```

   Either way, you'll get back one line of text starting with
   `ssh-ed25519 AAAA...`. Select that whole line, copy it, and paste it
   in when `./setup.sh` asks for your SSH public key.

   **What if you skip this?** The script will still finish, but it won't
   be able to fully lock down password logins until a key is in place, so
   don't restart your server until you've added one. If you already ran
   the script and left this blank, it's still fine, just reach out and
   we'll walk you through adding a key afterward before anything else
   changes on the box.
2. **Which AI provider you're using** (Gemini, OpenAI, or Anthropic) and
   **your API key** for it. You can get a key from:
   - Gemini: [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
   - OpenAI: [platform.openai.com/api-keys](https://platform.openai.com/api-keys)
   - Anthropic: [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys)
3. **A Telegram bot token** (optional). If you want a message confirming
   setup succeeded sent straight to you, add one here. Totally fine to
   skip this.

It takes 3 to 5 minutes to finish. Along the way it will:

- Create a dedicated user account and lock down SSH to key-only login
- Turn on a firewall and basic intrusion protection
- Install Docker and start your OpenClaw assistant
- Install a small watchdog that restarts your assistant automatically if
  it ever crashes (it can also auto-update itself, though that's off by
  default, see below)
- Send a real test message through your assistant to confirm everything
  is wired up correctly, and show you the result (and Telegram it to you
  too, if you added a bot token)

When it finishes, you'll see a summary with your dashboard login. **Save
that password somewhere safe**, it won't be shown again.

## Step 4: Confirm it worked

Look for this near the end of the output:

```
Verification PASSED — OpenClaw is live and answering with your API key.
```

That's it, your assistant is running. If you gave it a Telegram bot
token, you'll also get a short "CONFIRMED" message on Telegram as a
second confirmation.

---

## Keeping it updated

By default, your assistant restarts itself automatically if it ever
crashes, but it does **not** auto-update to newer versions. That's on
purpose, so a new release can't unexpectedly change how your assistant
behaves without you knowing. If you'd like automatic updates turned on,
edit `/opt/openclaw/watchdog.env` on your server and set
`OPENCLAW_AUTO_UPDATE=true`.

---

## Need help? Invite us in, on your terms

We never have standing access to your server. If something's broken and
you'd like us to take a look, run this on your server:

```
sudo ./support-access.sh on
```

This grants us SSH access. It stays on for as long as you need. There's
no clock that cuts us off mid-fix, since real troubleshooting sometimes
takes longer than expected. You'll see a confirmation like this:

```
Support access is now ON.
Turns off: when YOU run: sudo ./support-access.sh off
```

Once we let you know we're done and everything checks out, turn it back
off:

```
sudo ./support-access.sh off
```

Want to check whether access is currently on or off? Run:

```
sudo ./support-access.sh status
```

If you'd rather have a safety net that turns access off automatically in
case you forget, you can opt into one when you grant it. For example,
`sudo ./support-access.sh on --hours 24` turns itself off after 24 hours
on its own, but only if you ask for that. The default is no timer at all.

That's the whole support model in a sentence: you decide when we can get
in, and for how long. No standing keys, no passwords we hold, and nothing
that expires out from under you mid-fix.

---

## Questions

If anything in this guide doesn't work the way it's described, reach out
and we'll help you through it directly. No need to give us access to your
server just to have that first conversation.

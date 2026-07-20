# anh-nha — Family Install Guide

This guide walks a family member through installing anh-nha on their Android
phone and connecting it to the family Immich server. No technical knowledge
required — just follow the steps in order.

> **Time needed:** ~15 minutes
> **You need:** an Android phone running Android 9 or newer, a WiFi
> connection, and the account info Sinh gave you.

---

## Step 1 — Make sure Tailscale is on your phone

anh-nha talks to the family photo server over Tailscale (a private network).
Sinh should have already helped you install Tailscale. To check:

1. Open the **Tailscale** app on your phone.
2. You should see **Connected** at the top.
3. If not, tap **Sign in** and use the Google account Sinh shared with you.

If Tailscale is not installed, ask Sinh — he'll set it up for you.

---

## Step 2 — Install anh-nha

You have two options. **Option A is easiest.**

### Option A — Direct APK install (recommended)

1. On your phone, open this link in a browser:
   `https://github.com/sinh/anh-nha/releases/latest`
2. Download the `anh-nha-1.0.0.apk` file.
3. Your phone may warn "For your security, your phone is not allowed to
   install unknown apps from this source." Tap **Settings** → enable
   **Allow from this source** → tap back → tap **Install**.
4. Open the app called **anh-nha** (ảnh nhà).

### Option B — F-Droid install

Once anh-nha is published on F-Droid (Sinh will tell you when):

1. Install the **F-Droid** app from `https://f-droid.org`.
2. Open F-Droid, search for **anh-nha**.
3. Tap **Install**.

> F-Droid is a privacy-respecting alternative app store. It only hosts
> free, open-source apps and never sends your data anywhere.

---

## Step 3 — First-time setup

When you open anh-nha for the first time:

1. **Server URL** — type the address Sinh gave you (something like
   `http://100.x.y.z:2283`). The `100.x.y.z` part is the Tailscale
   address of the family photo server.
2. **Email** — your Immich account email (Sinh created one for each
   family member).
3. **Password** — your Immich password. (Ask Sinh if you forgot it.)
4. Tap **Sign in**.

You should see a green "Connected" indicator and the home screen.

---

## Step 4 — Grant photo permissions

anh-nha needs to see your photos to back them up. The first time it runs:

1. A popup will ask for **Allow access to photos and videos on this device**.
2. Tap **Allow**.

> The app can only see your photos — it cannot see your contacts, messages,
> location, or anything else.

---

## Step 5 — Confirm it's working

1. Take a photo with your phone camera.
2. Wait a moment (make sure you're on WiFi and Tailscale is connected).
3. Open anh-nha → look at the home screen.
   - **Tailscale peer: Online** ✓
   - **Queue pending: 0** (after sync) or **N** (still uploading) ✓
4. Tap **Dashboard** at the bottom. You should see your phone listed
   with a "last sync" time.
5. Tap the **Free Space** tab to see how much storage you can reclaim
   after backup.
6. Tap the **Verify** tab to confirm your photos are safely backed up.

That's it — your photos will now back up automatically whenever you're
on WiFi and Tailscale is connected.

---

## Troubleshooting

### "Tailscale peer: Waiting for server"

- Check the Tailscale app shows **Connected**.
- Check the laptop photo server is turned on (ask Sinh).
- The app will keep retrying every 30 seconds and auto-sync when the
  server comes back — no need to do anything.

### "Queue pending: N" and not decreasing

- Make sure you're on **WiFi**, not mobile data. anh-nha only uploads
  on WiFi to save your data plan.
- Wait a few minutes — large photos take time.

### Forgot your password

- Ask Sinh to reset your Immich password. He can do it from the Immich
  web UI on the laptop.

### "App not installed" on APK install

- Your phone may be running an Android version older than 9 (API 28).
  Check **Settings → About phone → Android version**. anh-nha requires
  Android 9 or newer.
- You may have an older copy of anh-nha installed. Uninstall it first,
  then install the new APK.

### Photos not showing up on the Immich web gallery

- Wait a minute — the server indexes photos in the background.
- Open anh-nha → Dashboard → check your phone's "last sync" time.
- If it's recent and "pending: 0", the upload finished — refresh the
  Immich web page.

---

## Privacy

- anh-nha sends your photos **only** to your family's Immich server,
  over your private Tailscale network.
- **No telemetry, no analytics, no ads.**
- **No Google Play Services required.** The app works on phones that
  have never installed the Play Store.
- Nothing about your usage ever leaves your Tailscale network.

---

## Getting help

- Ask Sinh — he built and runs the server.
- Bug reports: `https://github.com/sinh/anh-nha/issues` (Sinh will
  file them for you if you tell him what went wrong).

---

## Uninstalling

Settings → Apps → anh-nha → Uninstall. Your photos already uploaded to
the Immich server remain there — uninstalling the app from your phone
does **not** delete anything from the server.
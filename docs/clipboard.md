# 📋 Clipboard, shared with the phone

`ClipSync.swift` here, `ClipSync.kt` and the `:clipboard` module in `victor-phone-addons`.

| direction | how | gesture |
|---|---|---|
| Mac → phone | straight to `:55126/clip` on the hotspot, plus the Railway mailbox; Bluetooth (`R /clip?c=…`) only if the mailbox failed and the clip is short | none |
| phone → Mac | Railway mailbox, long-polled here | none when `CopyWatch` notices the copy; otherwise the "Clip to Mac" Quick Settings tile |

- **Sealed end to end**: AES-256-GCM with `CLIP_KEY` (64 hex digits) from `config.env`; the phone
  gets it from `tools/push-clip-key.sh`. The mailbox (`/api/clip/{mac,phone}` in
  `training-assistant`) holds ciphertext for five minutes and cannot read it. The `X-Bridge-Token`
  only keeps strangers out of the box. Clips are never logged in clear, on any of the three; until
  13 Nov 2026 the Mac's log kept the sealed `/clip?c=…` of a Bluetooth try, now only its route.
  The log is this user's only (0600) and rolls over at 5 MB.
- **The tile is there because of Android**: a background app may write the clipboard but not read
  it, and only a focused window can. The tile opens an invisible window for an instant.
- **The automatic way is `CopyWatch`**, an accessibility service that sees a tap on Copy or a
  "Copied" toast and opens the same invisible window. It is a guess: a copy with neither stays for
  the tile. KDE Connect's `logcat` trick was tried first and dropped: Android asks for each process,
  only with the app in front, so any restart turned it off silently.
- **Each clip carries an id and a time**, so the two ways of delivery cannot apply it twice and a
  ciphertext older than 10 min is refused. The ids seen are kept in memory only: within those 10
  min, a restart of either end would take the same ciphertext once more.
- **The toast never shows the content**, only "N characters" (Victor, 13 Nov 2026): no rule
  tells a password or a code from harmless text every time, and the screen may be shared. A lone
  link still shows its host.
- **A password copied on the Mac stays on the Mac**: a copy marked
  `org.nspasteboard.ConcealedType` (password managers) is not sent (13 Nov 2026; it was before).
- **A file from the phone is asked about first** ("Save a file from the phone?", `FileInbox.ask`),
  since any app on the phone can Share one; `FILES_FROM_PHONE=auto` in the config takes them
  unasked. A screenshot for the clipboard is not asked about. Saved files are quarantined in
  `~/Downloads` like a browser download, and their names lose control and right-to-left characters.
- **The clipboard itself is text only**; files have their own way, below. **No Bluetooth phone →
  Mac**: this Mac publishes no RFCOMM service, and the phone's own second service never worked (see
  `victor-phone-addons/CLAUDE.md`).
- **A toast says it arrived** (`ClipToast`, Emma 2026-11-08): top-right of the screen under the
  pointer, 4 s, kept up while hovered, a click dismisses it. A clip that is only a web address
  (`http(s)://…`, `www.…`) gets "Open in Browser" and 9 s. A panel of our own, not a system
  notification: no permission, never steals the focus. The preview is only the length (above). `GET /test/clip/toast?text=…`
  shows one without touching the clipboard (`&png=<path>` also draws it to a file).
- `GET /test/state` → `clip`: what went, by which way, and when. Never the text.

## 📥 Files and screenshots, phone → Mac

Share → **Mac Downloads** on the phone (`ShareToMac`, `FileOutbox.kt`) puts a file in `~/Downloads`
here (`FileInbox`). Every screenshot taken on the phone lands on this clipboard, unasked
(`ScreenshotWatch`, needs `READ_MEDIA_IMAGES`).

1. **Direct.** This Mac opens no port, so it pulls. A sealed offer (name, size, a key for that file,
   the phone's addresses) arrives through the mailbox and in `/status`, read every 5 s on the
   hotspot, so it also works with no internet. The file comes from `:55126/file` in encrypted frames
   (`FileFrames`), on any network the two share.
2. **Railway.** Not taken after 15 s, the phone uploads the same frames to `/api/file/{id}`
   (`file_relay.py` in `training-assistant`: memory only, 15 min at most, 40 MB) and offers it again.
3. **Or it gives up.** Not taken in 3 min, the file is deleted, from Railway too, and a notification
   says to share it again (Victor, 2026-11-07: nothing lands in the phone's Downloads). A screenshot
   goes silently: it is in the gallery anyway. Files a killed app left behind go the same way.

Not over Bluetooth: too slow for files, and the two ways above cover the real cases.

# 📋 Clipboard, shared with the phone

`ClipSync.swift` here, `ClipSync.kt` and the `:clipboard` module in `victor-phone-addons`.

| direction | how | gesture |
|---|---|---|
| Mac → phone | straight to `:55126/clip` on the hotspot, plus the Railway mailbox; Bluetooth (`R /clip?c=…`) only if the mailbox failed and the clip is short | none |
| phone → Mac | Railway mailbox, long-polled here | none when `CopyWatch` notices the copy; otherwise the "Clip to Mac" Quick Settings tile |

- **Sealed end to end**: AES-256-GCM with `CLIP_KEY` (64 hex digits) from `config.env`; the phone
  gets it from `tools/push-clip-key.sh`. The mailbox (`/api/clip/{mac,phone}` in
  `training-assistant`) holds ciphertext for five minutes and cannot read it. The `X-Bridge-Token`
  only keeps strangers out of the box. Clips are never logged, on any of the three.
- **The tile is there because of Android**: a background app may write the clipboard but not read
  it, and only a focused window can. The tile opens an invisible window for an instant.
- **The automatic way is `CopyWatch`**, an accessibility service that sees a tap on Copy or a
  "Copied" toast and opens the same invisible window. It is a guess: a copy with neither stays for
  the tile. KDE Connect's `logcat` trick was tried first and dropped: Android asks for each process,
  only with the app in front, so any restart turned it off silently.
- **Each clip carries an id and a time**, so the two ways of delivery cannot apply it twice and an
  old ciphertext cannot be replayed.
- **The clipboard itself is text only**; files have their own way, below. **No Bluetooth phone →
  Mac**: this Mac publishes no RFCOMM service, and the phone's own second service never worked (see
  `victor-phone-addons/CLAUDE.md`).
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
   (`file_relay.py` in `training-assistant`: memory only, 15 min, 40 MB) and offers it again.
3. **The phone keeps it.** Not taken in 3 min, or 15 on Railway, it goes to the phone's Downloads
   and a notification says so. A screenshot is simply dropped: it is in the gallery anyway.

Not over Bluetooth: too slow for files, and the two ways above cover the real cases.

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
- **Text only**, no images or files. **No Bluetooth phone → Mac**: this Mac
  publishes no RFCOMM service, and the phone's own second service never worked (see
  `victor-phone-addons/CLAUDE.md`).
- `GET /test/state` → `clip`: what went, by which way, and when. Never the text.

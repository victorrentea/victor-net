# Victor Net — the menu bar network icon

Extracted from Victor Addons on 2026-10-20 (Victor: *"not enough features to deserve its
own project … call it Victor Net"* — and then, about them, that they did). It replaces the
system Wi-Fi item, which Victor takes out of the menu bar.

## The icon

| the Mac is on…        | icon |
|-----------------------|------|
| a cable with an address | dashed ⇄ (drawn: a dashed line with an arrowhead at each end) |
| the phone's hotspot   | **the phone's own cellular bars**, 0–4, reported by the phone every 5 s; followed by the roaming GB left while the phone roams (orange < 3 GB, red < 1.5 GB, 📵 when the phone refuses the hotspot) |
| any other Wi-Fi       | the system Wi-Fi symbol, arcs filled by RSSI (−50 dBm full, −90 empty) |
| nothing               | Wi-Fi slashed |

**On the hotspot, the Mac↔phone Wi-Fi gets a glyph of its own only when it is weak**
(RSSI < −70 dBm, `NetworkLookPolicy.weakHotspotRSSI`). The phone is normally beside the
laptop; a second icon that always says "fine" is menu bar clutter. When the phone has been
left in another room, that link is the bottleneck, and then it shows.

A cable without an address (DHCP never answered) is not "wired": the icon follows the route
the bytes actually take.

## How the phone's bars get here

`PhoneLink`: while on the hotspot, `GET http://<default gateway>:55126/status` every 5 s —
the gateway *is* the phone, and `StatusServer.kt` in `victor-phone-addons` answers with the
data SIM's signal (`level`, `dbm`, `network`, `operator`) and the same roaming reading the
Bluetooth channel gives. Off the hotspot there is no IP route to the phone, so the 20-minute
roaming poll stays on Bluetooth (`PhoneRoamingMonitor`, docs/roaming-warning.md). A
Bluetooth page every 5 s would cost ~4 s each; this costs milliseconds.

No signal for 16 s (three missed polls) → the bars go faint rather than lying.

## The menu: which network is better

The question it answers (Victor): *"I sometimes have a hard time telling if the hotel Wi-Fi
has a larger bandwidth and a lower latency than my hotspot."*

```
🔌 Wired: not connected
🛜 Wi-Fi: Hotel-Guest · -61 dBm
📱 Phone: LTE · 3/4 · -97 dBm · Vodafone RO
──────────
📈 🛜 Hotel-Guest — 5 s average · best in 10 min
▁▂▅▇▃ ↓ In        1.2 MB/s    max 8.4 MB/s
▁▁▂▁▁ ↑ Out       40 KB/s     max 1.1 MB/s
      ⏱️ Latency  38 ms       best 21 ms
⚡ Test speed (25 MB) — last 21.0 MB/s, 2 h ago
🗂️ Other networks ›
──────────
Busiest apps — 5 s average
Google Chrome     ↓ 1.2 MB/s  ↑ 40 KB/s
…
```

- **No instantaneous numbers** — they jumped too much to read. The **5 s average**, and the
  **best 5 s average of the last 10 minutes on this network** (a sustained rate, not one
  spike). The bars are the last 20 seconds, the newest in the accent colour, scaled to that
  10-minute best.
- **In/Out are sampled all the time**, once a second, from the `en*` interfaces' kernel
  counters (`getifaddrs` — what `netstat -ib` prints). It costs nothing measurable, and it is
  why the window is already full when the menu opens. `utun*` is skipped: a VPN's bytes also
  cross `en0`. The counters are 32-bit and wrap at 4 GB; the diff is wrap-aware.
- **Latency is a TCP handshake to 1.1.1.1:443 every 5 s** (`LatencyProbe`), also always on:
  comparing two networks needs numbers taken the same way on both, whatever happened to be
  open. Shown as the mean of the last three, and the best in 10 minutes.
- **"Max seen" only says what something happened to use.** `⚡ Test speed` says what the link
  *can* do: one download from `speed.cloudflare.com`, 25 MB — **10 MB on the hotspot**, where
  every byte comes out of the phone's plan.
- **🗂️ Other networks** — each network's best of the day, last speed test, median latency
  and when it was last seen, from `~/.victor-net/networks.json`; the current one in bold.
  Keyed by SSID. An unnamed Wi-Fi (no Location grant) is not filed.
- **Busiest apps** — `nettop -d`, **only while the menu is open**; started in `menuWillOpen`,
  terminated in `menuDidClose`. Helpers fold into the outermost `.app`; a binary named after
  its version (`…/claude/versions/2.1.304`) is named after the folder above `versions`.
  - nettop runs *without* `-P` although only process rows are used: its stdout is
    block-buffered into a pipe, and the per-process summary alone never filled the 4 KB
    buffer — the first block arrived after the menu had closed.
  - Lines are handed to the main run loop with `RunLoop.main.perform(inModes: [.common])`:
    `DispatchQueue.main` is not drained while a menu tracks.
- **📵 Offline N min** appears at the top once two handshakes in a row failed (took over the
  row Victor Insomnia dropped on 2026-10-20, when Insomnia stopped caring about the internet).

## Settings and permissions

`~/.victor-net/config.env` (see `Config.swift`). Without a phone address the phone rows and
features stay off; the icon, Wi-Fi/wired rows and traffic work on any Mac.

macOS asks once for **Bluetooth** (the phone's beacon) and **Location** — CoreWLAN returns the
SSID only to apps holding Location, and without the SSID the hotspot cannot be told from any
other Wi-Fi. Signed with the stable local identity so rebuilds keep both grants.

## Hooks

`127.0.0.1:55126` — `/ping`, `/test/state` (network, icon, traffic, phone link, roaming),
`/test/menu/open?close=N`, `/test/hotspot`, `/test/roaming[/simulate/<pct>|/reset-dismissal]`.
`/test/state` answers while the menu is open (it reads through the run loop's common modes).

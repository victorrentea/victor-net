# Victor Net — the menu bar network icon

Extracted from Victor Addons on 2026-10-20 (Victor: *"not enough features to deserve its
own project … call it Victor Net"* — and then, about them, that they did). It replaces the
system Wi-Fi item, which Victor takes out of the menu bar.

## The icon

| the Mac is on…        | icon |
|-----------------------|------|
| a cable with an address | dashed ⇄ (drawn: a dashed line with an arrowhead at each end) |
| the phone's hotspot   | **the phone's own cellular bars**, 0–4, reported by the phone every 5 s; while the phone roams, a small yellow ⚠ in their top-left corner under 5 GB left, a red disc with a white ✕ there once nothing is left (or the phone refuses the hotspot) |
| any other Wi-Fi       | the system Wi-Fi symbol, arcs filled by RSSI (−50 dBm full, −90 empty) |
| nothing               | Wi-Fi slashed |

**On the hotspot, the Mac↔phone Wi-Fi gets a glyph of its own only when it is weak**
(RSSI < −70 dBm, `NetworkLookPolicy.weakHotspotRSSI`). The phone is normally beside the
laptop; a second icon that always says "fine" is menu bar clutter. When the phone has been
left in another room, that link is the bottleneck, and then it shows.

**No GB in the menu bar, and no pill on screen** (Victor, 2026-10-20): the badge says whether
to worry; the numbers are in the menu. The red bottom-left pill of Victor Addons was dropped.

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

**A snapshot, not a live view** (*"I don't really care about seeing live data. It distracts
me."*): every number is read when the menu opens and does not move while it is open. No
charts. The figures sit in **real tables** — an `NSGridView` as the row's view
(`MenuTable`), numbers right-aligned in monospaced digits.

```
🔌 Wired: not connected
🛜 Wi-Fi: victor · -54 dBm
📱 Phone: LTE · 3/4 · -97 dBm · Plus
──────────
📈 📱 victor
               avg over 5s   best in 10 min
↓ Download        1.2 MB/s         8.4 MB/s
↑ Upload           40 KB/s         1.1 MB/s
Latency             86 ms            81 ms
⚡ Test speed (10 MB) — last 21.0 MB/s, 2 h ago
🗂️ Compare networks ›     (one table: network · ↓ best · ↑ best · ⚡ · latency · seen)
──────────
Busiest apps — avg over 5s
Google Chrome   ↓ 1.2 MB/s   ↑ 40 KB/s
──────────
⛔ Roaming: 0.0 GB left of 13.4 GB · resets 2 Nov
    roaming now · used 37.8 GB · read now
⚙️ Roaming plan ›          (plan, reset day, + package, "Vodafone says…", *123#, protection)
🛜 Auto Mobile Hotspot  ✓
⏸️ Pause Claude on roaming data
```

- **↓ / ↑** — the **5 s average** and the **best 5 s average of the last 10 minutes on this
  network** (a sustained rate, not one spike). Sampled all the time, once a second, from the
  `en*` interfaces' kernel counters (`getifaddrs` — what `netstat -ib` prints): it costs
  nothing measurable, and it is why the window is full when the menu opens. `utun*` is
  skipped (a VPN's bytes also cross `en0`); the 32-bit counters' wrap is handled.
- **Latency** — a TCP handshake to 1.1.1.1:443 every 5 s (`LatencyProbe`), always on:
  comparing networks needs numbers taken the same way on each. Mean of the last three, and
  the best in 10 minutes.
- **⚡ Test speed** — "best" only says what something happened to use; this says what the
  link *can* do: one download from `speed.cloudflare.com`, 25 MB — **10 MB on the hotspot**.
- **🗂️ Compare networks** — every network's best of the day, last speed test, median latency
  and when it was last seen (`~/.victor-net/networks.json`), current one in bold. Keyed by
  SSID; an unnamed Wi-Fi (no Location grant) is not filed.
- **Busiest apps** — `nettop -d` **only while the menu is open** (`menuWillOpen` /
  `menuDidClose`); the table fills in **once**, ~2 s after opening, then stays. Helpers fold
  into the outermost `.app`; a binary named after its version (`…/claude/versions/2.1.304`)
  is named after the folder above `versions`.
  - nettop runs *without* `-P`: its stdout is block-buffered into a pipe, and the
    per-process summary alone never filled the 4 KB buffer — the first block arrived after
    the menu had closed. The connection rows push each second out.
  - Lines reach the main run loop with `RunLoop.main.perform(inModes: [.common])`:
    `DispatchQueue.main` is not drained while a menu tracks.
- **📵 Offline N min** at the top once two handshakes in a row failed (took over the row
  Victor Insomnia dropped on 2026-10-20).

## Roaming: every setting is made on the Mac

Victor, 2026-10-20: *"the application on the mobile shouldn't do anything really"*. The phone
still **counts** (only it sees its roaming bytes) and still **refuses the hotspot** under its
reserve, so it keeps the settings — but they are made from **⚙️ Roaming plan** here and sent
with `GET http://<gateway>:55126/config?planMb=&resetDay=&adjustMb=&guardOff=`, only while on
its hotspot:

- **Monthly plan** and **Resets on day** — the cycle.
- **Extra this cycle — add a package** — `adjustMb`, which the phone files under the current
  cycle's start, so it disappears by itself at the reset.
- **Vodafone says remaining is …** — the same `adjustMb`, solved for
  `remaining = plan + adjust − used`; it is also how our count and Vodafone's are realigned.
- **Ask Vodafone (\*123#)** — the phone dials `*123#` on its data SIM (`sendUssdRequest`,
  CALL_PHONE) and returns the text; if it holds an "N GB" / "N MB", one click uses it as the
  remaining. **There is no Vodafone RO API** to read the allowance from (searched 2026-10-20:
  no documented API, no open-source client for My Vodafone RO); `*123#` is the one source.
  Not applied by itself until its wording has been seen: a wrong number would disarm the
  reserve.
- **Hotspot protection off until the reset** — `guardOff`: the phone stores the next reset
  as the moment it turns itself back on.

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

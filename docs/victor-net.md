# Victor Net — the menu bar network icon

Extracted from Victor Addons on 2026-10-20 (Victor: *"not enough features to deserve its
own project … call it Victor Net"* — and then, about them, that they did). It replaces the
system Wi-Fi item, which Victor takes out of the menu bar.

## The icon

| the Mac is on…        | icon |
|-----------------------|------|
| a cable with an address | `< ‐ ‐ >` — open angle brackets, two dashes |
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
Wi-Fi                                    [ON]       ← macOS's first line: a real switch
best last hour, MB/s        ↓     ↑   ping  seen   ← click = test the speed now
<‐‐> Ethernet                                       ← always listed, greyed without a cable
✓ 📱 victor                7.3   1.2    87  now     ← ✓ = in use, phone glyph for the hotspot
  wifi Hotel-Guest         3.1   0.4    38  35 min  ← Wi-Fi arcs at its strength; click = join
› More                       ◌ searching             ← click: all others unfold below, live
──────────
↺ Roaming: 22.6/60.9 GB left until 2 Nov           ← click = ask Vodafone (*123#, via the phone)
✓ 🔒 Auto-stop hotspot at 1.0 GB left
  ⏸️ Pause Claude on roaming
✓ ((o)) Auto-start Mobile Hotspot                   ← Victor's hotspot glyph, drawn
──────────
⚡ Test speed (downloads 10 MB)
Wi-Fi Settings…
Quit                                                ← no ⌘Q: its column widened the menu
```

- **Rows are drawn views** (`MenuRows.swift`): fixed-x columns that line up whatever the
  names (tab stops in a title could not), a rounded highlight under the pointer, a click that
  acts — none of which AppKit gives a view-backed item. 300 pt wide, like the native menu.
- **More unfolds in place** (`toggleOthers`; "Other Networks" until 2026-10-21): rows inserted
  below it while the menu stays open, rescanned back to back, gone when the menu closes (or on a
  second click); 🔒 = secured. A secured network this Mac does not know asks for its password in
  the app's own dialog: big type, the password **in clear by default**, a "Hide password" box
  (Victor, 2026-10-21; handing over to System Settings › Wi-Fi was tried and rejected).
- **Proof that it is searching** (Victor, 2026-10-21: *"prove me that you're searching"*): on
  the More row's right, a spinner + "searching" while a CoreWLAN scan is in flight, then
  "N in range · Ns ago". More is grey, folded or not. Scans run only while the menu is open,
  back to back (a new one once the last is over, at most every 2 s from its start), folded or
  not — never in the background (a scan takes ~5 s and briefly stalls the link).
  `GET /test/state` → `network.scan`; `GET /test/more-row` draws the row in both states.

- **Laid out like macOS's own Wi-Fi menu**, which it is meant to replace for daily use: the
  known/measured networks in range with their numbers, *More* (all in range,
  strongest first, a password asked only for a secured network this Mac does not know), and
  the Wi-Fi switch (`networksetup -setairportpower`, no admin). Captive portals and hidden
  networks stay with *Wi-Fi Settings…*.
- **Narrow table**: numbers only, the unit in the header (`↓ MB/s`), "seen" for the last time.
- **Roaming is one group**, Pause Claude included. Native ticks now (the check column is there
  anyway for the network ✓).
- **The speed test is a line near the bottom**, out of the way.
- **The phone's bars follow the phone's own scale**: computed on the Mac from dBm
  (≥ −90 → 4, ≥ −100 → 3, ≥ −110 → 2, ≥ −120 → 1). At −102 dBm the S24 showed 2/4 while
  Android's `SignalStrength.level` said 3 (AOSP's LTE thresholds are −98/−108/−118).

- **No Wired / Wi-Fi / Phone status rows** (Victor: the icon and the ✓ already say it).
- **One row per network, clickable** (`networkRows`): every Wi-Fi **in range** (the last
  scan, `cachedScanResults`; a fresh scan starts in the background each time the menu opens)
  that this Mac knows (*Known networks*) or has measured, plus **Ethernet, always**, which
  reads `not connected` when unplugged. ✓ = the one in use; a click on another **joins it**
  (`networksetup -setairportnetwork`, password from the keychain). Out of range = off the
  list, but its numbers stay in the book and return with it. Rows, not a grid view, because
  a grid row cannot be clicked: the columns are right-aligned tab stops.
- **The cable glyph** is `< ‐ ‐ >` — open angle brackets and two dashes (after filled, then
  hollow triangles were turned down) — the same in the menu bar and, tinted green / yellow /
  grey, on the Ethernet row.

- **One table, every network, in the main menu** (Victor, 2026-10-20: *"not a submenu, right
  in the main screen"*) — the current one in bold, its row fresh from the live window. No
  "avg over 5s" column and no ⚡ column any more: a row is a network's **best 5 s average**
  of the day (a sustained rate, not one spike), its latency and when it was **last seen**
  (`now`, `35 min`).
- **↓ / ↑** Sampled all the time, once a second, from the
  `en*` interfaces' kernel counters (`getifaddrs` — what `netstat -ib` prints): it costs
  nothing measurable, and it is why the window is full when the menu opens. `utun*` is
  skipped (a VPN's bytes also cross `en0`); the 32-bit counters' wrap is handled.
- **Latency** — a TCP handshake to 1.1.1.1:443 every 5 s (`LatencyProbe`), always on:
  comparing networks needs numbers taken the same way on each. Mean of the last three, and
  the best in 10 minutes.
- **⚡ Test speed** — "best" only says what something happened to use; this says what the
  link *can* do: one download from `speed.cloudflare.com`, 25 MB — **10 MB on the hotspot**.
- **All numbers in MB/s, two decimals** in every table — a column mixing KB/s and MB/s
  cannot be read across (Victor, 2026-10-20). The current network's name heads the first
  column of the main table.
- **🗂️ Compare networks** — every network's best of the day, last speed test, median latency
  and when it was last seen (`~/.victor-net/networks.json`), current one in bold. Keyed by
  SSID; an unnamed Wi-Fi (no Location grant) is not filed.
- **No busiest-apps section for now** (Victor, 2026-10-20). `TrafficPolicy` still holds the
  `nettop -d` parsing (no `-P`: its pipe output is block-buffered and the per-process summary
  alone never filled the 4 KB buffer), ready for when it comes back.
- **📵 Offline N min** at the top once two handshakes in a row failed (took over the row
  Victor Insomnia dropped on 2026-10-20).

## Roaming: every setting is made on the Mac

Victor, 2026-10-20: *"the application on the mobile shouldn't do anything really"*. The phone
still **counts** (only it sees its roaming bytes) and still **refuses the hotspot** under its
reserve, so it keeps the settings — but they are made from **⚙️ Roaming plan** here and sent
with `GET http://<gateway>:55126/config?planMb=&resetDay=&adjustMb=&guardOff=`, only while on
its hotspot. **The items sit in the main menu**, not a submenu:

- **Monthly plan** and **Resets on day** — the cycle.
- **Extra this cycle — add a package** — `adjustMb`, which the phone files under the current
  cycle's start, so it disappears by itself at the reset.
- **Vodafone says remaining is …** — the same `adjustMb`, solved for
  `remaining = plan + adjust − used`; it is also how our count and Vodafone's are realigned.
- **Ask Vodafone (\*123#)** — the phone dials `*123#` on its data SIM (`sendUssdRequest`,
  CALL_PHONE) and returns the text; if it holds an "N GB" / "N MB", one click uses it as the
  remaining. **There is no Vodafone RO API** to read the allowance from (searched 2026-10-20:
  no documented API, no open-source client for My Vodafone RO); `*123#` is the one source.
  **Vodafone answers by SMS, not on screen** (*"Veti primi mesajul … prin SMS"*), so the button
  gets only that sentence for now. The SMS (seen 2026-10-20) carries the firm figure as
  `22.86GB din Trafic rmg optiune` — the roaming package left — next to the general
  "până la 13.38GB … în roaming în SEE" fair-use line. Reading it automatically would take a
  notification listener on the phone; until then, "Vodafone says remaining is …" by hand.
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

## CoreWLAN never on the main thread (2026-10-21)

Twice that evening `airportd` stopped answering for minutes (`networksetup -getairportnetwork`
hung too, `airportd` at 0% CPU), and Victor Net froze: the main thread sat in
`CWFInterface.SSID` (XPC to `airportd`) from `RoamingDataWatch.tick`, so the menu and the icon
were dead. Every CoreWLAN read now runs on `NetworkState`'s `readQueue` into a `WifiSnapshot`
(ssid, rssi, power, last scan, known networks); the main thread reads only the snapshot, and a
read still hanging is skipped, not queued. `GET /test/state` → `network.wifi_read_age_s` says
how stale it is. If `airportd` itself is wedged: `sudo killall airportd` (launchd restarts it).
It started while the menu scanned back to back; not proven to be the cause.

After a join with a password the app checks, 3 s later, that macOS lists the network among its
known networks (so it auto-joins later, app or no app); if not, it adds it with
`networksetup -addpreferredwirelessnetworkatindex … WPA2` and logs `🛜 remember`.

## 🎵 The phone's music pauses while Walkie Talkie dictates (2026-10-29)

`PhoneMediaPause` listens on Walkie Talkie's own `ws://127.0.0.1:8920` (the `MusicBridge`
that pauses Chrome tabs) — Walkie is not changed and does not know about it. On
`{"type":"dictation","active":true}` it sends the phone `GET /media?hold=1&ttl=90`, renewed
every 30 s, and `hold=0` at the end; through `PhoneLink`, so HTTP on the hotspot and
`R /media…` over Bluetooth elsewhere (a page: the pause lands a few seconds late there).
The phone takes a transient audio focus, so the player stops and resumes by itself; the ttl
lets the music go if the resume never arrives. State: `/test/state` → `media_pause`.

# Victor Net — the phone's icon in the menu bar

Extracted from Victor Addons on 2026-10-20 (Victor: *"not enough features to deserve its
own project … call it Victor Net"* — and then, about them, that they did).

**Only the phone since 2026-11-12.** For three weeks it also stood in for the system Wi-Fi item
(the list of networks, joining them, the Wi-Fi switch). Victor: *"we are overburdening the same
application with too many responsibilities … the selection of Wi-Fi networks will be done from the
classical menu in Mac, and this application will remain only responsible for the integration with
the phone."* The system Wi-Fi item is back in the menu bar; what went: the networks of today and in
range, *More…*, joining with its password dialog, the Wi-Fi switch, *Wi-Fi Settings…*, the cable /
Wi-Fi / offline icons. It stays its own app, not merged back into Victor Addons: each one's
deploys would restart the other.

## The icon: the phone's bars, always

| the Mac is on…        | icon |
|-----------------------|------|
| the phone's hotspot   | **the phone's own cellular bars**, 0–4, reported by the phone every 5 s, with the data SIM's type small over the short bars like on the phone (`5G`, `4G` — the phone's `LTE` shown as Samsung does, `3G`, `2G`; Victor, 2026-11-11) |
| the hotspot, with no internet behind it | the bars empty, a red **!** in their corner |
| anything else, or nothing | the bars of the phone's **last answer, faded** (45 %): `/status` over the home Wi-Fi or Bluetooth, at most 15 min old (`NetworkLookPolicy.awayFreshFor`); without one, four faint bars |

On both, while the phone roams: a small yellow ⚠ in the bars' top-left corner under 5 GB left, a
red disc with a white ✕ there once nothing is left (or the phone refuses the hotspot). The route
itself (which Wi-Fi, how strong, the cable) is macOS's icon next to it.

**No GB in the menu bar, and no pill on screen** (Victor, 2026-10-20): the badge says whether
to worry; the numbers are in the menu. The red bottom-left pill of Victor Addons was dropped.

A cable without an address (DHCP never answered) is not "wired": the menu's *this network*
row and the book follow the route the bytes actually take.

## How the phone's bars get here

`PhoneLink`: while on the hotspot, `GET http://<default gateway>:55126/status` every 5 s —
the gateway *is* the phone, and `StatusServer.kt` in `victor-phone-addons` answers with the
data SIM's signal (`level`, `dbm`, `network`, `operator`) and the same roaming reading the
Bluetooth channel gives. Off the hotspot there is no IP route to the phone, so the 20-minute
roaming poll stays on Bluetooth (`PhoneRoamingMonitor`, docs/roaming-warning.md). A
Bluetooth page every 5 s would cost ~4 s each; this costs milliseconds.

No signal for 16 s (three missed polls) → the bars go faint rather than lying.

**⇄ — try the other SIM** (Victor, 2026-11-11): on the hotspot, when the SIM *not* carrying data has
at least 2 bars more than the data SIM (both from `signal.sims`, fresh), a slanted ⇄ sits in the
corner above the short bars and the whole icon blinks (full / 30 %, once a second). The tooltip
names both SIMs. The switch stays Victor's, by hand on the phone. The roaming badge takes the same
corner and wins. `SimSwitchHint`; `GET /test/sim-hint/simulate/on|off`; `/test/state` → `sim_switch_hint`.

## The menu: which network is better

The question it answers (Victor): *"I sometimes have a hard time telling if the hotel Wi-Fi
has a larger bandwidth and a lower latency than my hotspot."*

**A snapshot, not a live view** (*"I don't really care about seeing live data. It distracts
me."*): every number is read when the menu opens and does not move while it is open. No
charts. **One exception** (Victor, 2026-10-29): when the Mac moves to another network while
the menu is open — the hotspot comes up, say — the network rows are redrawn in place
(`refreshNetworksIfChanged`, checked every second), so the ✓ and the new row show up.

```
((o)) Start Hotspot                     retrying in 23s  ← the hotspot button, alone at the top (2026-11-11), see below
──────────
✓ wifi Hotel-G…   3.1↓MB/s ⋅ 0.4↑MB/s ⋅ 38↕︎ms ⋅ now │  ← **this network, now**: the one row left of the list, to hold against the SIMs;
                                                        Ethernet with the cable glyph; not there on the hotspot (its numbers are the data SIM's);
                                                        "Offline 4 min" in its place when offline; never clickable
╭ ✓ ((o)) victor                                 │  ← the hotspot, framed with its SIMs (2026-11-08); ✓ while this Mac is on it; not clickable
│   ✓ ⁴ᴳ▂▄▆₃ₛ Orange 7.3↓MB/s ⋅ 1.2↑MB/s ⋅ 87↕︎ms ⋅ now │  ← each SIM by operator: phone's bars for it now, ✓ = data SIM, its own numbers (`sim:<name>`)
╰     ▂▄▆ Vodafone 3.1↓ ⋅ 0.4↑ ⋅ 38↕︎ms ⋅ 2 h (grey) │  ← the SIM not carrying data: its old numbers in grey
   (off the hotspot, on any Wi-Fi or the cable: both SIMs always, numbers in grey — only what was measured here
    before (`SimLog`, by GPS place), else none; bars only from a real reading ≤ 15 min old — the phone's
    `/status` off the hotspot — else no icon. Each opening asks for it (at most once in 30 s): over the home
    Wi-Fi (~0.3 s), else over Bluetooth (~3 s); the bars and their age then update in the open menu)
   the SIM bars like the phone's (Victor, 2026-11-11): its type (5G / 4G) over the short bars, the reading's age
    ("3s") at their bottom-right, after them; the name moves right by that much (`Icons.cellularWithAgeWidth`)
   ⚡ before a SIM's numbers (not in use): its ↓ is the last speed test there (Victor, 2026-11-09)
──────────
✓ wifi Prefer home over hotspot                     ← only with PREFERRED_SSID in the config
✓ ((o)) Auto-Start Hotspot on no Internet           ← Victor's hotspot glyph, drawn
⚡ Run speed test (25MB)                             ← 10MB on the hotspot
──────────
↺ ✈️ Roaming: 22.6/60.9 GB left until 2 Nov        ← click = ask Vodafone (*123#, via the phone)
✓ ✈️ Roaming: Allow Claude
✓ 🔒 ✈️ Roaming: Auto-Stop Hotspot < 1 GB             ← only while roaming: the phone decides, see roaming-warning.md
──────────
🔋 Phone: 63% ⚡ · 12s ago · Wi-Fi                  ← greyed; ⚡ = charging; always its age (ticking while open) and how it came:
                                                       Hotspot (PhoneLink, 5 s), Wi-Fi (PhoneLan), BT (roaming poll), Internet (Railway)
Built Nov 5, 20:50
Quit                                                ← no ⌘Q: its column widened the menu
```

- **Rows are drawn views** (`MenuRows.swift`): fixed-x columns that line up whatever the
  names (tab stops in a title could not), a rounded highlight under the pointer, a click that
  acts — none of which AppKit gives a view-backed item. 320 pt wide like the native menu, wider
  only as far as the widest number cell shown needs (`MenuRowLayout.cellWidth`, measured at
  every open; the numbers carry their units since 2026-11-08). Thin spaces around the `⋅`.
- **The only scan left** is for the hotspot's name, so the button knows Start from Stop: while
  the menu is open and this Mac is not on the hotspot, at most every 5 s (a scan takes ~5 s and
  briefly stalls the link). `PreferredWifi` scans for home on its own clock. `GET /test/state` →
  `network.scan`; `GET /test/menu/render` draws the button's states and the rows to a PNG.
- **Roaming is one group**, Pause Claude included. Native ticks now (the check column is there
  anyway for the network ✓).
- **The speed test is a line near the bottom**, out of the way.
- **The phone's bars follow the phone's own scale**: computed on the Mac from dBm
  (≥ −90 → 4, ≥ −100 → 3, ≥ −110 → 2, ≥ −120 → 1). At −102 dBm the S24 showed 2/4 while
  Android's `SignalStrength.level` said 3 (AOSP's LTE thresholds are −98/−108/−118).

- **Other networks are not listed** (2026-11-12). The book (`~/.victor-net/networks.json`) still
  files every network's best numbers as before; only the one in use is shown.
- **The cable glyph** is `< ‐ ‐ >` — open angle brackets and two dashes (after filled, then
  hollow triangles were turned down), on the Ethernet row.

- **A row's numbers** are a network's (or a SIM's) **best 5 s average** of the last hour (a
  sustained rate, not one spike), its latency and when it was **last seen** (`now`, `35 min`).
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
- **The book** (`~/.victor-net/networks.json`) keeps every network's best, last speed test and
  median latency, keyed by SSID; an unnamed Wi-Fi (no Location grant) is not filed. Only the
  network in use and the SIMs are shown from it.
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
features stay off; the *this network* row and the traffic numbers work on any Mac.

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
(ssid, rssi, last scan); the main thread reads only the snapshot, and a
read still hanging is skipped, not queued. `GET /test/state` → `network.wifi_read_age_s` says
how stale it is. If `airportd` itself is wedged: `sudo killall airportd` (launchd restarts it).
It started while the menu scanned back to back; not proven to be the cause.

A known network can still fail with `-3900 tmpErr`: macOS's own Wi-Fi menu can join it, but
`airportd` gives `networksetup` no password (`Missing password for upper auth 8`,
`hasPassword=0`), drops the current network, and auto-join returns to the top of the list. Seen
2026-11-06 going from the hotspot back to the home Wi-Fi. That move is now only `PreferredWifi`'s,
which passes the password from `~/.victor-net/wifi-passwords.json` (`WifiPasswords`, owner-only:
`{"<ssid>": "<password>"}`). The menu's password dialog that filled it is gone with the list
(2026-11-12): a new entry is added by hand.

## 🎵 The phone's music pauses while Walkie Talkie dictates (2026-10-29)

`PhoneMediaPause` listens on Walkie Talkie's own `ws://127.0.0.1:8920` (the `MusicBridge`
that pauses Chrome tabs) — Walkie is not changed and does not know about it. On
`{"type":"dictation","active":true}` it sends the phone `GET /media?hold=1&ttl=90`, renewed
every 30 s, and `hold=0` at the end; through `PhoneLink`, so HTTP on the hotspot and
`R /media…` over Bluetooth elsewhere (a page: the pause lands a few seconds late there).
The phone takes a transient audio focus, so the player stops and resumes by itself; the ttl
lets the music go if the resume never arrives. State: `/test/state` → `media_pause`.

**A missing SDP record is re-read before it is believed (2026-11-12).** For 35 minutes every
pause and roaming poll failed with "not publishing the beacon channel", while the phone's own
`dumpsys bluetooth_manager` showed `VictorPhoneAddons` listening on channel 10. With the link
up, macOS answers the query from its cache, and that cache had been read while the phone was
re-creating its socket. A standalone fresh link + query listed the record at once, and the
next poll went through. `PhoneChannelOpener` now treats "no record" like a refused channel:
drop the link, query the phone again, and only then report it missing.

## 📶 Which SIM, place by place (2026-11-08)

`SimLog`: on the hotspot, every `LatencyProbe` handshake is filed under the place (the Mac's
location fix, rounded to ~1 km; `?` without one) and the data SIM the phone names in `/status`
(`signal.sim`, with `rsrp` and `sinr`). Capacity can't be read off traffic, which only shows what
was used, so after ten quiet minutes on one SIM in one place the 10 MB ⚡ test runs **once for that
SIM there**, never on roaming data. Kept in `~/.victor-net/sim-places.json`; `GET /test/state` → `sim_log`. The manual
measurements so far are in `victor-phone-addons/docs/sim-benchmarks.md`.

**Under the hotspot's row, while it is in use: the phone's SIMs**, each with the menu bar's GSM bars, ✓ on
the one carrying data, and the numbers the hotspot's row had: best ↓ ↑, latency, last used — filed per SIM
(`sim:<name>` in `networks.json`; a SIM switch starts a new window, as a network switch does). The
`victor` row itself keeps no numbers while they are shown (no SINR text either: the bars said enough) (`signal.sims` — the phone keeps both
registered for calls, so a new place, an airport where Vodafone has nothing, can be judged without
switching). The switch itself stays Victor's,
by hand on the phone (Android lets only system apps change the data SIM, and Samsung Routines have
no action for it — checked on the phone, 2026-11-08).

## 🔋 The phone's battery in the menu bar (2026-11-06)

`PhoneBatteryBar`: an item of its own, there only at 30% or less, unplugged, read in the last two
hours. A battery shaped like the Mac's, no number; its red charge blinks once a second and is as
wide as the charge left. `GET /test/phone-battery/simulate/<pct>` shows it (`off` clears).

## 🔋 The phone's battery, for the tablet's soundboard (2026-10-29)

The tablet shows the **phone's** charge in its top bar, not its own (Victor: "the tablet's
battery is stupid"). The phone's `/status` carries `"battery":{"pct":63,"charging":false}`;
`PhoneBatteryBook` keeps the **freshest** one from whichever answer arrives — `PhoneLink` every
5 s on the hotspot, `PhoneLan` every 10 min on the home Wi-Fi, `PhoneCloud` every minute from
Railway, `PhoneRoamingMonitor` every 20 min over Bluetooth elsewhere. No Bluetooth poll of its own (Victor chose it over a 5-min
page), so off the hotspot and away from home it can be 20 min old, or hours when the phone's
Bluetooth is out of reach (4 Nov 2026: 17 h).

**`PhoneCloud`** is the one that works from any network: the phone pushes every change of its
percentage to Railway, plus a keep-alive every 10 min (`BatteryRelay.kt` in
`victor-phone-addons`; without it a phone lying still would read as stale), and this asks
`RELAY_URL/api/phone-battery` once a minute, except on the hotspot, where the phone is at hand.
It needs `RELAY_URL` and `RELAY_TOKEN` (the tablet bridge's token) in `config.env`.

**`PhoneLan`** asks `/status` on the phone's Wi-Fi address, a poll of its own: once in 10 min
(Victor: no more often), on arrival at most once a minute. The address is found by asking the
whole subnet, so it runs **only on `PREFERRED_SSID`, on a /24 or smaller**: on a client's
network that sweep is a port scan. Between sweeps it asks only the address that answered. `GET /phone/battery` → `{"pct":63,"charging":false,"age_s":120}` (`{"pct":-1}`
until the phone answers once); Victor Addons reads it and passes it on in its `/ping`.

**The SIMs under `victor` on any other Wi-Fi too (12 Nov 2026).** They used to vanish while the hotspot
was on but the Mac sat on another network (the hotel's), because the frame once ended in a Stop row.
Stop is the button at the top since 11 Nov, so the SIM rows, their numbers and their roaming rows
stay, to compare with the Wi-Fi in use.

**Only what was measured here (12 Nov 2026).** A SIM not carrying the data shows its numbers from
this place's `SimLog` spot, or none. Its best anywhere (`sim:<name>`) used to stand in, so in
Utrecht yoxo showed the ⚡ 3.0 MB/s speed test run in Bucharest as if run here.

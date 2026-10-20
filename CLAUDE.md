# Victor Net

Menu bar app: **the network icon** (cable ⇄ / the phone's bars on its hotspot / Wi-Fi), the
traffic and latency of the current network compared with the others, and everything this Mac
does with Victor's Android phone (`victor-phone-addons`): asking it for its hotspot over
Bluetooth, its roaming allowance (set from here: plan, reset day, packages, *123#), ⏸ Claude on roaming data. Extracted from
`victor-macos-addons` on 2026-10-20; public repo `victorrentea/victor-net`, branch `main`.

**Read the doc of the zone before touching its code** — the details there are load-bearing:

| doc | covers |
|---|---|
| [docs/victor-net.md](docs/victor-net.md) | the icon, `PhoneLink` (signal every 5 s over the hotspot), the menu: 5 s average + 10-min best, latency probe, ⚡ speed test, other networks, busiest apps |
| [docs/hotspot-fallback.md](docs/hotspot-fallback.md) | 🛜 asking the phone for its hotspot when offline (Bluetooth as the trigger, the Samsung routine, the home geofence) |
| [docs/roaming-warning.md](docs/roaming-warning.md) | 📶 roaming allowance: the phone's reading, the reserve, the meter, ⏸ Pause Claude (`~/.victor-net/roaming-data.json`, read by `~/.claude/hooks/roaming-gate.sh`) |

- **Build**: `swift build && swift test`
- **Deploy after any code change**: `git push`, `./build-app.sh`, then restart by PID:
  `kill $(cat /tmp/VictorNet.pid); open "/Applications/Victor Net.app"`. Never `pkill`, never
  the bundle binary.
- **Login item**: `./install-startup.sh` (LaunchAgent `ro.victorrentea.victor-net`).
- **Test hooks**: `127.0.0.1:55126`, listed in `HttpServer.swift`. **Log**: `/tmp/victor-net.log`.
- **Public repo**: no personal paths, no phone address, no SSID, no home in the code — all of
  that is `~/.victor-net/config.env` (`Config.swift`).
- The phone half (signal + roaming JSON on `:55126/status`, the beacon, the reserve) is in
  `~/workspace/victor-phone-addons`.

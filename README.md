# Victor Net

A macOS menu bar app that shows **how this Mac is online** and **how well**:

- the icon is a dashed ⇄ on a cable, the Wi-Fi arcs on Wi-Fi, or — on your Android phone's
  hotspot — **the phone's own cellular signal**, with the Wi-Fi to the phone shown only when
  that link is weak;
- the menu shows download/upload as a 5-second average with a 20-second bar chart and the
  best of the last 10 minutes, latency (a TCP handshake every 5 s), an on-demand speed test,
  the busiest apps (only while the menu is open), and the same figures for **every network
  it has seen**, so the hotel Wi-Fi and the phone's hotspot can be compared side by side.

With the companion Android app (not published), it also asks the phone for its hotspot over
Bluetooth when the Mac is offline, and tracks the roaming allowance.

## Install

```sh
git clone https://github.com/victorrentea/victor-net && cd victor-net
./build-app.sh          # needs Xcode command line tools; installs /Applications/Victor Net.app
./install-startup.sh    # start at login
```

Optional settings in `~/.victor-net/config.env` — see `Sources/VictorNet/Config.swift`.
macOS asks for Location (needed to read the Wi-Fi name) and Bluetooth (phone features only).

MIT licence.

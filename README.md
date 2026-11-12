# Victor Net

A macOS menu bar app for **the Android phone this Mac tethers to**. Picking a Wi-Fi stays with
macOS's own menu.

- the icon is **the phone's own cellular signal**: full while the Mac is on its hotspot, faded
  from its last answer otherwise;
- the menu shows the network in use — best download/upload (5-second average), latency (a TCP
  handshake every 5 s), an on-demand speed test — next to the same figures for each of the
  phone's SIMs, so the hotel Wi-Fi and the hotspot can be held side by side.

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

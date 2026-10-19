# Peripherals

A small macOS menu bar app that runs a Razer **BlackWidow V4 Pro 75%** keyboard and a **Basilisk V3 Pro** mouse without Razer Synapse.

- **Lighting.** A dim, cool white at rest. While [DuoChart](https://github.com/deoxylabs/duochart) plays, the keys show the album art and breathe on the beat; star power washes them blue. Brightness is adjustable.
- **The keyboard's OLED.** While Apple Music plays it shows the track: the cover in 16 greys, then title, artist and album. Otherwise it shows a clock with the date and live CPU and memory figures.
- **Sleep and idle.** The keys, the mouse and the OLED go dark while the displays sleep, and come back on wake. After 10 minutes without input from any device they dim. The keyboard's own timers, which only count keypresses and would blank or screensave the OLED mid-use, are switched off while the app runs and restored when it quits.
- **Batteries.** Both devices' batteries are shown in the menu bar panel.
- **Boot animation.** A custom power-on animation for the keyboard: a spinning double helix that becomes the wordmark.

It talks to the devices directly over HID: no kernel extension, no Synapse. The protocol is documented in [PROTOCOL.md](PROTOCOL.md).

## Requirements

- macOS 26 or later; built with Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- An Apple Development signing identity: the app runs with the hardened runtime and is launched by launchd.
- Keyboard plugged in over USB. The 2.4 GHz dongle mode (`1532:02B4`) isn't supported yet.

## Build and install

```sh
echo 'export DEVELOPMENT_TEAM=XXXXXXXXXX' > Local.env   # your team ID; Local.env is gitignored
./install.sh
```

`install.sh` does the following:
- generates the Xcode project
- builds Release
- withdraws any earlier copy's launchd registration
- copies the app to `/Applications` and opens it

The opened copy registers the bundled launch agent and quits. launchd then runs the app from then on: at login, and again after a crash.

The first run needs two permissions:
- **Input Monitoring,** for the mouse: its control interface is also the pointer. If no prompt appears, add the app by hand in System Settings → Privacy & Security → Input Monitoring, then restart it (`launchctl kickstart -k gui/$(id -u)/com.deoxylabs.peripherals`).
- **Automation of Music,** requested by `osascript` (see `OsaScript.swift` for why).

## Tests

```sh
xcodegen generate
xcodebuild -project Peripherals.xcodeproj -scheme Peripherals test
```

The tests pin the wire formats against values captured from the original prototypes, which were checked on the hardware. They cover the report checksum, nibble order, the clock's parameter record, the 0x09 slot layout, and the colour handling.

## Licence

[MIT](LICENSE). The deoxy wordmark in `Resources/` is a Deoxy Labs trademark and isn't covered by it; swap it out in your own builds. Razer, BlackWidow, Basilisk and Synapse are trademarks of Razer Inc.; this project isn't affiliated with Razer.

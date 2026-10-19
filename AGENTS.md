# Working on Peripherals

Read [README.md](README.md) for what the app does and [PROTOCOL.md](PROTOCOL.md) for the device protocol. This file is the map and the rules.

## Layout

| Path | What it is |
|---|---|
| `project.yml` | XcodeGen spec, the source of truth; the `.xcodeproj` is generated and gitignored |
| `Sources/App.swift` | `@main`, the app delegate (launch model below), and `Model`, which wires everything and holds the menu's state |
| `Sources/Panel.swift` | The menu bar panel (SwiftUI, `MenuBarExtra` window style) |
| `Sources/Service.swift` | The launchd agent via `SMAppService.agent`, single-instance hand-over, retiring the old Python LaunchAgents |
| `Sources/HID/DeviceHub.swift` | IOHIDManager on its own run-loop thread. Opens the keyboard's interfaces 3 and 5 and the mouse's interface 0, all shared. Reconnects; retries opens that TCC refused. `send` / `query` / `sendOutput`. |
| `Sources/HID/RazerReport.swift` | The 90-byte Razer report |
| `Sources/HID/FirmwarePolicy.swift` | The keyboard's own idle handling (OLED dim, screensaver, auto sleep, lighting dim), switched off while the app runs and restored after |
| `Sources/HID/OledLink.swift` | Interface-5 uploads: begin, 60-byte data packets, one ack per packet. Blocking; only call it from the OLED queue. |
| `Sources/Lighting/` | `LightingEngine` (30 fps loop on its own queue; DuoChart UDP feed on 127.0.0.1:52737) and `ArtworkGrid` (cover → per-key colours) |
| `Sources/Oled/` | `OledController` (state machine on its own queue, 1 Hz), `Screens` (layouts and the byte formats the firmware reads), `Render` (CoreGraphics greys, 4-bit packing, dithering), `BootAnimation` |
| `Sources/Watchers/` | `MusicWatcher` (Music's `playerInfo` distributed notification, plus osascript for the launch-time state and artwork), `OsaScript`, `SystemStats` |
| `Support/` | Info.plist, entitlements, the bundled launch agent plist |
| `Tests/` | Pure-logic tests of the wire formats |

## Threads

- **HID:** a dedicated thread runs the IOHIDManager's run loop. Matching, removal and input-report callbacks all happen there.
- **Lighting:** a serial queue with a 30 fps timer.
- **OLED:** a serial queue with a 1 Hz timer. Uploads block on it while they wait for acks, which arrive on the HID thread.
- **Main actor:** `Model`, the UI and `MusicWatcher`'s notifications.

The classes shared across threads are `@unchecked Sendable` and confine their state to their own queue. Keep it that way, rather than adding locks across components.

## Rules that came from breaking things

- **Never send a first byte of 0x30 or 0x31 on interface 5.** It opens a passthrough to the display MCU's bootloader. `OledLink.send` has a precondition for this; keep it.
- **Open HID devices shared** (`kIOHIDOptionsTypeNone`). Exclusive on the mouse's interface 0 freezes the cursor.
- **The manager uses a run loop, not a dispatch queue.** With a dispatch queue, devices arrive already activated, and `IOHIDDeviceRegisterInputReportCallback` traps.
- **Uploads are flash writes on the display MCU.** Upload when content changes (once per track; clock backgrounds once a day). Anything that changes every second goes through the RAM paths: class 0x17 ids 0x09 and 0x0a.
- **Pixels: left pixel in the low nibble.**
- **The keyboard's LED matrix is 6×18.** Its own matrix query says so.
- **Frame writes are never acknowledged,** and devices silently drop what they show. Resend unchanged lighting frames every few seconds.
- **The 0x09 live buffer has fixed slots by item id,** not a list.
- **The keyboard's idle timers count keypresses only,** so they'd dim, blank and screensave the OLED while the mouse is in use. `FirmwarePolicy` switches them off while the app drives the screen and restores the keyboard's own values on Quit or in Razer mode. It reads before writing, because they're flash settings. Idleness comes from the Mac (`SystemStats.idleSeconds`, any input device). `OledController.watchdog` re-applies the home screen if anything replaces it.
- **A still home image (type 1) goes black after a while** while 0x8D still reports it, and keypresses don't wake it. Selecting it again (0x02 + 0x0D, same values) brings it back, so `showTrack` re-selects it every 20 s. The clock (type 6) redraws every second and isn't affected.
- **TCC:** a launchd agent may not show permission prompts, and on Macs with AMFI relaxed nothing non-Apple-signed may. So:
  - AppleScript goes through `/usr/bin/osascript` with responsibility disclaimed.
  - Input Monitoring is requested from the hand-opened copy. The agent retries opens and needs a restart once it's granted, because IOKit caches the denial.
- **Tests:** an XCTest host launch must not touch launchd or the devices. `AppDelegate` returns early when `XCTestConfigurationFilePath` is set. If you change start-up, keep that guard first. Otherwise a test run registers the agent for real.

## Checking a change

- `xcodebuild … test` for the formats.
- `./install.sh` to deploy, then watch the log: `log stream --predicate 'subsystem == "com.deoxylabs.peripherals"'`. Categories are `hid`, `lighting`, `oled` and `app`.
- `pmset displaysleepnow` exercises the dark/wake path.
- Lighting and the OLED can only be judged by looking at the hardware. Ask someone to.

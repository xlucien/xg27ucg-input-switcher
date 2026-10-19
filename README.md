# XG27UCG Input Switcher

A lightweight macOS menu-bar utility for switching the ASUS ROG Strix XG27UCG between DisplayPort, HDMI, and USB-C inputs using DDC/CI.

## Features

- Native macOS menu-bar app
- DisplayPort, HDMI, and USB-C switching
- Global hotkeys:
  - `Ctrl + F1` — DisplayPort
  - `Ctrl + F2` — USB-C
  - `Ctrl + F3` — HDMI
  - `Ctrl + Alt + 1` — DisplayPort
  - `Ctrl + Alt + 2` — USB-C
  - `Ctrl + Alt + 3` — HDMI
- Bundled `m1ddc`; Homebrew is not required for the DMG build
- Automatically finds the connected XG27UCG by model name to avoid controlling another monitor
- Detects a connected MEIZU HiFi audio device and automatically switches the monitor to USB-C
- Detects a connected Corsair K70 keyboard and automatically switches the monitor to USB-C
- Retries automatically after wake while the monitor's DDC/CI connection is recovering
- Debounces K70 HID removal events so disconnecting the keyboard reliably rearms the next automatic switch

Detection is event-driven through CoreAudio and IOKit HID notifications. The app checks once at launch and is then dormant until macOS reports a relevant device change. It triggers once when a matching device appears and rearms after the device is disconnected, so it does not repeatedly force the input while the device remains connected.

## Requirements

- Apple-silicon Mac
- ASUS XG27UCG connected through a DDC/CI-capable link
- DDC/CI enabled in the monitor's OSD menu
- macOS 13 or later

## Install

Download the DMG from Releases, open it, and drag **XG27UCG Input Switcher** to Applications. Launch it once; a display icon then appears in the macOS menu bar.

The app is ad-hoc signed, not notarized. On first launch, macOS may require right-clicking the app and choosing **Open**.

## Build

```sh
./build.sh
```

The build script requires Apple's Command Line Tools and an installed copy of `m1ddc` at `/opt/homebrew/bin/m1ddc`. It creates an app bundle and DMG under `dist/`.

## Input values

The app writes VCP code `0x60` using the standard MCCS values:

- DisplayPort 1: `15` (`0x0F`)
- HDMI 1: `17` (`0x11`)
- USB-C: `26` (`0x1A`) on the tested XG27UCG firmware

## Third-party software

The distributed app bundles [m1ddc](https://github.com/waydabber/m1ddc), licensed under the MIT License. Its license is included in the app bundle and distribution.

## License

The switcher source code is available under the MIT License. See `LICENSE`.

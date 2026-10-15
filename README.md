# XG27UCG Input Switcher

A lightweight macOS menu-bar utility for switching the ASUS ROG Strix XG27UCG between DisplayPort, HDMI, and USB-C inputs using DDC/CI.

## Features

- Native macOS menu-bar app
- DisplayPort, HDMI, and USB-C switching
- Global hotkeys:
  - `Control + Option + 1` — DisplayPort
  - `Control + Option + 2` — HDMI
  - `Control + Option + 3` — USB-C
- Bundled `m1ddc`; Homebrew is not required for the DMG build
- Automatically finds the connected XG27UCG by model name to avoid controlling another monitor

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
- USB-C: `27` (`0x1B`)

## Third-party software

The distributed app bundles [m1ddc](https://github.com/waydabber/m1ddc), licensed under the MIT License. Its license is included in the app bundle and distribution.

## License

The switcher source code is available under the MIT License. See `LICENSE`.

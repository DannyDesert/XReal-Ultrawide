# UltraXReal

**A free, open-source macOS menu bar app that creates a virtual ultrawide display for XReal Air AR glasses.**

Turn your XReal Air glasses into a 21:9 ultrawide monitor. UltraXReal creates a virtual 2560×1080 display that macOS scales onto the glasses' 1920×1080 panel — giving you 33% more horizontal workspace with no extra hardware.

No head tracking. No IMU. No bloatware. Just a clean, static ultrawide HUD.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)
[![Download DMG](https://img.shields.io/github/v/release/DannyDesert/XReal-Ultrawide?label=Download%20DMG&color=brightgreen&style=for-the-badge)](https://github.com/DannyDesert/XReal-Ultrawide/releases/latest/download/UltraXReal-v1.0.0.dmg)

---

## Download

**[Download UltraXReal-v1.0.0.dmg](https://github.com/DannyDesert/XReal-Ultrawide/releases/latest/download/UltraXReal-v1.0.0.dmg)** — Open the DMG, drag to Applications, launch. That's it.

> On first launch, macOS may warn about an unidentified developer. Right-click the app > **Open** to bypass.

---

## What It Does

1. Creates a virtual 2560×1080 (21:9) display using Apple's `CGVirtualDisplay` API
2. The virtual display appears in **System Settings → Displays** as a real monitor
3. Drag windows onto it, use Spaces, full-screen apps — everything works
4. Mirror it to your XReal Air glasses via USB-C for an ultrawide desktop in your face

```
┌─────────────────────────────────────────────────┐
│  MENU BAR APP                                   │
│  SwiftUI · Toggle on/off · Resolution picker    │
├─────────────────────────────────────────────────┤
│  VIRTUAL DISPLAY ENGINE                         │
│  CGVirtualDisplay · Display mirroring           │
└─────────────────────────────────────────────────┘
         ▼ XReal Air (USB-C DisplayPort) ▼
```

## Features

- **Menu bar app** — lives in your menu bar, no dock icon clutter
- **One-click toggle** — enable/disable the ultrawide display instantly
- **Multiple resolutions:**
  - 2560 × 1080 (21:9) — default, best balance
  - 3440 × 1440 (21:9 HiDPI) — sharper text
  - 3840 × 1080 (32:9) — super ultrawide
- **Auto-mirror** — mirrors the virtual display to your XReal Air automatically
- **Launch at login** — set it and forget it
- **Sleep/wake aware** — recreates the display after your Mac wakes up
- **Clean teardown** — no phantom displays left behind when you quit

## Requirements

- **macOS 13.0 (Ventura)** or later
- **XReal Air** glasses (original, Air 2, or Air 2 Pro) connected via USB-C
- **Xcode 15+** to build from source

## Installation

### Build from Source

```bash
git clone https://github.com/DannyDesert/XReal-Ultrawide.git
cd XReal-Ultrawide
open UltraXReal/UltraXReal.xcodeproj
```

1. In Xcode, select **"Sign to Run Locally"** under Signing & Capabilities
2. Build and run (`Cmd + R`)
3. The UltraXReal icon appears in your menu bar

### Pre-built Release

Check [Releases](https://github.com/DannyDesert/XReal-Ultrawide/releases) for pre-built `.app` bundles.

> **Note:** This app uses Apple's private `CGVirtualDisplay` API and cannot be distributed via the Mac App Store. Install from source or from GitHub Releases.

## Usage

1. **Connect** your XReal Air glasses via USB-C
2. **Click** the display icon in the menu bar
3. **Click** "Enable Ultrawide"
4. A new "UltraXReal" display appears in System Settings → Displays
5. **Drag windows** onto the virtual display, or set it as your primary display
6. **Click** "Mirror to XReal Air" to send the ultrawide to your glasses
7. Done — you now have an ultrawide desktop in your AR glasses

### Manual Mirroring

If auto-mirror doesn't work for your setup:

1. Open **System Settings → Displays**
2. Click **Arrange**
3. Hold **Option** and drag the UltraXReal display onto your XReal Air display
4. The glasses now show the ultrawide desktop

## How It Works

UltraXReal uses Apple's private `CGVirtualDisplay` API — the same API used by [BetterDisplay](https://github.com/waydabber/BetterDisplay), [FluffyDisplay](https://github.com/tml1024/FluffyDisplay), and Chromium's test infrastructure. This API:

- Creates a virtual display that macOS treats as a real, physical monitor
- Supports custom resolutions, refresh rates, and HiDPI scaling
- Has been stable across macOS Ventura, Sonoma, Sequoia, and Tahoe

The app then uses `CGConfigureDisplayMirrorOfDisplay` to mirror the virtual ultrawide onto the XReal Air's physical 1920×1080 panel. macOS handles the scaling — the glasses show a compressed ultrawide image.

### Why Not Nebula / XReal's Official App?

- Nebula is heavy, requires head tracking, and doesn't support a simple static ultrawide
- UltraXReal is ~200 lines of code, does one thing well, and gets out of your way
- No IMU, no 3DoF, no spatial computing — just more screen real estate

## Project Structure

```
UltraXReal/
├── UltraXReal.xcodeproj
└── UltraXReal/
    ├── UltraXRealApp.swift          # @main, menu bar setup
    ├── MenuBarView.swift             # SwiftUI menu bar dropdown
    ├── VirtualDisplayManager.swift   # CGVirtualDisplay lifecycle
    ├── DisplayMirrorHelper.swift     # Automated display mirroring
    ├── DisplayResolution.swift       # Resolution presets
    ├── Settings.swift                # UserDefaults wrapper
    ├── CGVirtualDisplay-Bridge.h     # Bridging header for private API
    ├── Assets.xcassets/
    ├── Info.plist
    └── UltraXReal.entitlements
```

## Known Limitations

- **Private API** — `CGVirtualDisplay` is undocumented by Apple. It could break in a future macOS update (though it's been stable for 4+ major releases).
- **No App Store** — Private APIs mean this must be distributed outside the App Store.
- **No head tracking** — This is intentional. UltraXReal is a static HUD. For head-tracked virtual displays, use Nebula or similar.
- **Display mirroring** — Auto-mirror works in most cases, but some display configurations may require manual mirroring in System Settings.

## Contributing

Contributions welcome! Some ideas:

- [ ] Auto-detect XReal Air connection via IOKit USB monitoring
- [ ] Auto-enable when glasses connect, disable when disconnected
- [ ] Custom resolution input
- [ ] Window management helpers (snap to left/right halves)
- [ ] App icon design
- [ ] Homebrew cask formula
- [ ] DMG packaging with background image

## References

- [FluffyDisplay](https://github.com/tml1024/FluffyDisplay) — Simplest CGVirtualDisplay Swift wrapper
- [Lumen](https://github.com/trollzem/Lumen) — Sunshine fork with vd_helper subprocess pattern
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) — Production virtual display manager
- [macOS Headers — CGVirtualDisplay](https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/CoreGraphics/1336/CGVirtualDisplay.h) — Reverse-engineered private API headers
- [Chromium virtual_display_mac_util.mm](https://chromium.googlesource.com/chromium/src/+/d441ddf663e568fe8383d59a31e0dfacb9d9535b/ui/display/mac/test/virtual_display_mac_util.mm) — Google's test implementation

## License

[MIT](LICENSE) — do whatever you want with it.

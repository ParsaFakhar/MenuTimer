<div align="center">

  <img src="assets/AppIcon.png" width="64" alt="MenuTimer Logo">

  # MenuTimer

  **A lightweight multi-timer that lives in your macOS menu bar.**  
  Run multiple timers simultaneously, add time on the fly, and get alerted when time is up.

  [![Download Latest Release](https://img.shields.io/github/v/release/ParsaFakhar/MenuTimer?label=download&style=for-the-badge&color=2ea44f)](https://github.com/ParsaFakhar/MenuTimer/releases/latest)
  ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?style=for-the-badge&logo=apple&logoColor=white)
  ![SwiftUI Native](https://img.shields.io/badge/SwiftUI-Native-FA7343?style=for-the-badge&logo=swift&logoColor=white)

  <br>

  <img src="assets/menubar.png" width="340" alt="MenuTimer panel interface">

</div>

---

## Features

- **Multiple Timers**: Run multiple countdowns side by side without clutter.
- **Live Status**: Displays a live countdown in the menu bar for the timer ending soonest.
- **Quick Adjustments**: Instantly add `+ 1m` or `+ 5m` while a timer is running or idle.
- **Audible Alarm**: Plays a chime and updates the menu bar status when time is up.
- **Fast Input**: Type durations in intuitive formats like `25`, `1:30`, or `3:05:32`.
- **Persistent Storage**: Saved timer presets persist across app launches.
- **Native SwiftUI**: Zero external dependencies, contained in a single swift source file.

---

## Requirements

- macOS 14 (Sonoma) or later

---

## Installation

### Pre-built Binary
1. Download `MenuTimer.zip` from the [Latest Release](https://github.com/ParsaFakhar/MenuTimer/releases/latest).
2. Extract the archive and drag **MenuTimer.app** into your `/Applications` folder.
3. Open the app. If macOS prevents launch because it is unnotarized:
   - Go to **System Settings → Privacy & Security**
   - Scroll to **Security** and click **Open Anyway** next to MenuTimer
   - Confirm with your system password or Touch ID

*Alternatively, strip the quarantine attribute via Terminal:*

```bash
xattr -dr com.apple.quarantine /Applications/MenuTimer.app
```

---

## Usage

Click the timer icon in the menu bar to toggle the control panel.

| Action | Method |
| :--- | :--- |
| **Start / Pause** | Click the timer row or the play/pause button |
| **Add Time** | Click `+ 1m` / `+ 5m` (extends active run or increases preset length) |
| **Reset** | Click the circular reset arrow to restore full duration |
| **Stop Alarm** | Click the stop button or reset the timer |
| **Snooze** | Click `+ 1m` or `+ 5m` while the alarm is active |
| **Delete** | Click the pink **✕** button |
| **Create Timer** | Type a label and duration at the bottom, then press **Return** or **+** |
| **Quit** | Click **Quit** at the bottom of the panel or press `⌘Q` |

### Time Format Shortcuts

| Input | Resulting Duration |
| :--- | :--- |
| `25` | 25 minutes |
| `1:30` | 1 minute 30 seconds |
| `1:00:00` | 1 hour |

> **Note**: Default installs include three built-in presets: **Focus** (25 min), **Break** (5 min), and **Tea** (3 min).

### Behavior Details
- The alarm repeats every **2.5 seconds** and silences itself after **~30 seconds**.
- Saved timer definitions persist, but **active running counts reset when quitting**.
- Runs purely as a menu bar app (does not appear in the Dock or App Switcher).

---

## Build from Source

Requires Xcode Command Line Tools:

```bash
# Install command line tools (if needed)
xcode-select --install

# Clone and compile
git clone [https://github.com/ParsaFakhar/MenuTimer.git](https://github.com/ParsaFakhar/MenuTimer.git)
cd MenuTimer
./build.sh
open MenuTimer.app
```

`build.sh` compiles `MenuTimer.swift` via `swiftc`, constructs the `.app` bundle, links icons, and applies an ad-hoc signature.

---

## Customization

Adjust default constants directly inside `MenuTimer.swift` before building:

```swift
private let alarmSoundName = "Glass"    // Frog, Hero, Ping, Submarine, Funk, Sosumi, Purr
private let alarmRepeatSeconds = 2.5    // Gap between alarm repeats
private let alarmMaxRepeats = 12        // Max repeats before auto-silence (~30 s)
private let panelTitle = "timers"       // Header text in dropdown
private let menuBarSymbol = "timer"     // Fallback SF Symbol
```

---

## Project Structure

```text
MenuTimer/
├── MenuTimer.swift     # Complete application codebase
├── build.sh            # Build script & bundle packager
├── AppIcon.icns        # App icon file
└── MenuBarIcon.png     # Menu bar icon (tinted automatically for light/dark mode)
```

---

## Uninstall

Quit the app, move `MenuTimer.app` from `/Applications` to the Trash, and optionally clear saved preferences:

```bash
defaults delete com.local.menutimer
```

---

## License

[MIT](LICENSE)

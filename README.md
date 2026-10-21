<div align="center">

<img src="docs/screenshots/icon.png" width="128" alt="Keylog icon: a keyboard seen through a thermal camera">

# Keylog

**Every key you press, counted. Never recorded.**

A native macOS menu bar app that turns your typing into a live heatmap: keys, groups, apps, speed, clicks and mouse travel, all on your Mac and nowhere else.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![No network](https://img.shields.io/badge/network-none-2ea44f)
![No dependencies](https://img.shields.io/badge/dependencies-0-2ea44f)
![Liquid Glass](https://img.shields.io/badge/macOS%2026-Liquid%20Glass-7b61ff)
![MIT](https://img.shields.io/badge/license-MIT-blue)

<img src="docs/screenshots/hero.jpg" alt="Keylog on a Mac desktop: the dashboard, the glass panel under the menu bar icon, and the floating counter" width="100%">

</div>

<br>

## Why Keylog

You type tens of thousands of keys a day. Keylog shows you how: which keys work hardest, when you're fastest, which apps take your words, how far your mouse travels. And it does it without ever knowing what you typed.

- **Counts, never records.** Keylog stores how many times each key was pressed, per hour. Never the text, never the order, never where you clicked.
- **Nothing leaves your Mac.** There is no network code in the app at all. No analytics, no accounts, no cloud.
- **Truly native.** Swift, SwiftUI and AppKit. No Electron, no web views, no third-party libraries. About 0% CPU at rest and around 40 MB of memory.
- **Made for macOS 26.** Liquid Glass panel and widget, with a frosted fallback on macOS 14 and 15.

<br>

## Features

<table>
<tr>
<td width="52%"><img src="docs/screenshots/panel.jpg" alt="The glass panel in light and dark mode"></td>
<td>

### Today, one click away

Click the keyboard icon in the menu bar for a glass panel with everything about today:

- Total keys, split into **letters, numbers, special characters, space and other keys**, with counts and percentages
- Keys per hour, with the current hour live
- Left and right clicks, mouse travel and scroll distance in real metres
- Typing speed: keys per minute while typing, estimated WPM and your fastest second
- Your five hottest keys, drawn as heat-coloured keycaps
- The last 7 or 30 days, by keys, clicks, mouse or scroll

Right-click or ⌃-click the icon for a quick menu.

</td>
</tr>
</table>

<table>
<tr>
<td>

### A counter that floats

A tiny glass pill shows today's total over everything you do, on every desktop and over full-screen apps.

- **Never in the way:** clicks pass straight through, and it fades when your pointer comes near
- **Feels alive:** a gentle 1% pulse on every key press, off with Reduce Motion
- **Yours to style:** dark glass, light glass or text only; any font, size, weight, colour, shape and opacity
- **Snaps into place:** drag it anywhere, it snaps to the corners and remembers its spot on each display
- Hold ⌃ and click it for the menu

</td>
<td width="52%"><img src="docs/screenshots/widget.jpg" alt="The floating counter in dark glass, light glass and text-only styles"></td>
</tr>
</table>

### The keyboard heatmap

Every key coloured by how hard it works, on a real thermal scale from cold blue to red. A log scale keeps quieter keys visible next to Space and E. Hover any key for its exact count and share, filter by app, and look at a day, a week, a month, a year or all time.

<img src="docs/screenshots/keyboard.jpg" alt="Keyboard heatmap for a month, with the most pressed keys listed below" width="100%">

Keys are counted by their physical position, so switching between QWERTY, AZERTY, Dvorak or any input source never scrambles your history. Labels follow your current layout.

### A dashboard for the long view

Day, week, month, year or all time, with keyboard shortcuts for all of it (⌘1 to ⌘5, ⌘← ⌘→, ⌘T). Bars stack by key group; hover for exact numbers, click a bar to open that day or month.

<img src="docs/screenshots/overview.jpg" alt="Dashboard overview for a week: total keys, group tiles, keys per day stacked by group, share donut and typing speed" width="100%">

<table>
<tr>
<td width="50%">

**Apps.** Which apps take your keys, clicks and scrolling. Click one to see its own keyboard heatmap.

<img src="docs/screenshots/apps.jpg" alt="Apps view with bars for keys, clicks and scroll per app">

</td>
<td width="50%">

**Mouse.** Left and right clicks, real-world travel measured from your screens' physical size, and scrolling.

<img src="docs/screenshots/mouse.jpg" alt="Mouse view with clicks, travel and scroll">

</td>
</tr>
</table>

**Calendar.** A whole year at a glance, one square per day, coloured by how much you typed. Click any day to open it.

<img src="docs/screenshots/calendar.jpg" alt="Calendar view: a year of days coloured by activity" width="100%">

### Settings that feel like macOS

A proper Settings window with toolbar tabs: launch at login, what the menu bar shows, which day your week starts, per-app and mouse tracking, every widget option with a live preview, CSV and JSON export, and a delete-everything button that asks twice.

<div align="center">
<img src="docs/screenshots/settings.jpg" alt="Widget settings with a live preview" width="62%">
</div>

<br>

## Privacy, in detail

Keylog needs the macOS **Input Monitoring** permission to see key presses. It uses a *listen-only* event tap: it can't change, block or delay anything you type, and macOS hands it a copy of each event after it reaches your app.

| Keylog stores | Keylog never stores |
|---|---|
| How many times each physical key was pressed, per day and per app | The characters you type |
| Counts for letters, numbers, special characters, space and other keys, per hour | The order of your keys |
| Left and right clicks, mouse travel and scroll distance | Where you click, or what's on screen |
| The name of the app in front (can be turned off) | Window titles, URLs or file names |

- Everything lives in one SQLite file: `~/Library/Application Support/Keylog/keylog.sqlite`. Open it with any SQLite tool and see for yourself.
- The character a key types is used for one thing only, deciding its group, and then discarded. You can check: it's [one function](Sources/KeylogCore/KeyClassifier.swift).
- Password fields are hidden from every app by macOS (secure input), so they're never counted.
- No network code exists in the app. No analytics, no update checks, no sync.

<br>

## How counting works

| Rule | Why |
|---|---|
| Holding a key down counts **once** | Auto-repeat isn't typing |
| Only **left and right** clicks count | Side and wheel buttons are for navigating, not clicking |
| Keys from **virtual keyboards** don't count | Mouse tools like USB Overdrive turn side buttons into shortcuts through one; every keyboard can be switched on or off in Settings |
| ⌘ ⇧ ⌥ ⌃ fn count only when **tapped on their own** | A capital letter is one key press, not two; ⌘C counts as one letter |
| Shortcuts still light up their modifiers **on the heatmap** | So you can see how hard ⌘ really works |
| Groups follow the **character typed** | ⇧1 types `!`, so it counts as special |
| The heatmap follows the **physical key** | Layout switches never scramble history |
| A new day starts at **midnight, local time** | Also after sleeping through midnight or changing time zone |
| Typing speed counts only **minutes you were typing** | Coffee breaks don't drag your average down |

<br>

## Install

Keylog builds with Apple's free **Command Line Tools**. Xcode isn't needed.

```sh
xcode-select --install                  # once, if you don't have the tools
git clone https://github.com/irfanabdulhameed/keylog.git
cd keylog
./scripts/make-cert.sh                  # once: a local signing certificate (recommended)
./scripts/build.sh                      # builds and installs ~/Applications/Keylog.app
open ~/Applications/Keylog.app
```

On first launch Keylog asks for **Input Monitoring**. Switch it on in System Settings → Privacy & Security → Input Monitoring and Keylog carries on by itself.

**Why the certificate?** macOS ties the Input Monitoring permission to the app's signature. `make-cert.sh` creates a self-signed certificate in your login keychain (no Apple account needed), so the permission survives every rebuild. Without it the app is signed ad hoc and macOS asks again after each build.

<br>

## Under the hood

| | |
|---|---|
| **Input** | One listen-only `CGEventTap` for keys, modifiers, left and right clicks, mouse moves and scrolls; re-enabled at once if macOS ever switches it off |
| **Storage** | SQLite, one row per hour, written every 30 seconds and before sleep or quit; a few MB per year |
| **UI** | SwiftUI and AppKit: `NSStatusItem`, a borderless glass panel, a non-activating floating `NSPanel`, Swift Charts |
| **Performance** | Counts gathered in memory; UI updates coalesced; a hidden panel never redraws |
| **Requirements** | macOS 14 or later, Apple silicon or Intel |

```
Sources/KeylogCore/   counting: event tap, rules, recorder, SQLite store, periods
Sources/Keylog/       the app: menu bar, glass panel, widget, dashboard, settings
Tests/                counting rules, midnight, sleep, time zones, speed, mouse, apps
scripts/              build.sh, make-cert.sh, test.sh, make-icon.swift
```

### Development

```sh
./scripts/test.sh                           # the test suite
swift build && .build/debug/Keylog --snapshot ~/Desktop/keylog-shots
```

`--snapshot` renders every screen with 400 days of demo data into PNGs, using a throwaway database. The screenshots in this README come from it. The app icon is drawn in code by [`make-icon.swift`](scripts/make-icon.swift).

<br>

## Roadmap

- **Goals and streaks:** a daily target ring and a streak counter
- **Finger and hand balance:** which finger works hardest, left hand vs right, home-row share
- **Layout lab:** how much finger travel Colemak or Dvorak would save on *your* typing
- **Shortcut stats:** your most used ⌘ shortcuts
- **Break reminders:** a nudge after long unbroken typing sessions
- **Year in review:** a shareable card of your typing year
- **More keyboards:** ISO and JIS layouts, numpad, per-keyboard stats
- **Exclude apps:** never count chosen apps
- **Signed releases:** notarized downloads and a Homebrew cask

<br>

## FAQ

**Isn't this a keylogger?**
The name is a nod, but no. A keylogger records what you type. Keylog only keeps tallies: "E was pressed 4,210 times today in Notes". The text, the order and the timing between keys are never stored, and nothing ever leaves your Mac.

**Will it slow my typing?**
It can't. The event tap is listen-only, so macOS delivers your key presses to your app first and gives Keylog a copy.

**Why don't password fields count?**
macOS turns on secure input for password fields and hides those keys from every app, Keylog included.

**How do I start over?**
Settings → Data → Delete All Data. To remove Keylog completely, quit it, delete the app and `~/Library/Application Support/Keylog`, and remove it from Input Monitoring.

<br>

## License

[MIT](LICENSE) © 2026 Irfan Abdul Hameed

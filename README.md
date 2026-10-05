# thumbd 🖱️

**Make the Logitech MX Master 3 gesture button work on macOS without Logi Options+.**

thumbd is a tiny background daemon. It talks HID++ 2.0 to the mouse, takes over its buttons
and turns them into keyboard shortcuts you can bind to anything: Raycast commands, Mission
Control, desktop switching… It's written in Swift and has no dependencies.

|   | What you do | Default shortcut |
|---|---|---|
| 👆 | Tap the thumb button | `⌃⌥⌘F1` |
| ⬆️ | Hold it and move up | `⌃⌥⌘F2` |
| ⬇️ | Hold it and move down | `⌃⌥⌘F3` |
| ⬅️ | Hold it and move left | `⌃←` (desktop to the left) |
| ➡️ | Hold it and move right | `⌃→` (desktop to the right) |
| 🔘 | Press the button below the wheel | `F12` |

Tested with an MX Master 3 over Bluetooth on Apple Silicon.

---

## Quick start

```sh
./scripts/install.sh          # build, sign, install to ~/.local/bin and start at login
```

Then grant **both** permissions to `~/.local/bin/thumbd` in **System Settings → Privacy &
Security**:

- **Input Monitoring**: to talk to the mouse.
- **Accessibility**: to send the shortcuts.

Use `+` to add the binary and ⌘⇧G to type the path. thumbd picks the permissions up on its
own within ~10 s.

Check that it's working:

```sh
tail -f ~/Library/Logs/thumbd.log
# ✓ Wireless Mouse MX Master 3: button 0x00C3 diverted (divert=1 rawXY=1): tap ⌃⌥⌘F1, ↑ ⌃⌥⌘F2, …
```

> **Managed Mac with Santa?** Use `./scripts/install.sh --swiftc` and see
> [Code signing & Santa](#code-signing--santa).

---

## Configuration

Edit `~/.config/thumbd/config.json`. It's created with these defaults:

```json
{
  "tap": "ctrl+alt+cmd+f1",
  "gestures": {
    "up": "ctrl+alt+cmd+f2",
    "down": "ctrl+alt+cmd+f3",
    "left": "ctrl+left",
    "right": "ctrl+right"
  },
  "threshold": 50,
  "button": "0x00C3",
  "buttons": {
    "0x00C4": "f12"
  },
  "devices": []
}
```

| Key | Meaning |
|---|---|
| `tap` | Shortcut for a tap: press and release without moving. |
| `gestures` | Shortcuts for hold + move: `up`, `down`, `left`, `right`. Any of them can be left out. While the button is held, the cursor stays still. |
| `threshold` | How far to move before it counts as a gesture, in raw sensor units (50 ≈ 1.3 mm). |
| `button` | The button that does gestures. `0x00C3` is the thumb button. |
| `buttons` | Extra buttons: button ID → shortcut, fired on press. A remapped button loses its normal function. |
| `devices` | Only manage mice whose name contains one of these. Empty = all. |

**Shortcuts** are written as modifiers + key, e.g. `cmd+shift+space`, `ctrl+left` or `⌃⌥⌘F1`:

- Modifiers: `ctrl`, `alt`/`opt`, `cmd`, `shift`, `fn`.
- Keys: `a`–`z`, `0`–`9`, `f1`–`f20`, arrows, `space`, `return`, `tab`, `esc`, `home`, `end`,
  `pageup`, `pagedown`…

**Button IDs** for your mouse come from `thumbd list`. On the MX Master 3:

| ID | Button |
|---|---|
| `0x00C3` | thumb |
| `0x00C4` | below the wheel |
| `0x0053` | back |
| `0x0056` | forward |
| `0x0052` | middle |

**Apply changes:**

```sh
~/.local/bin/thumbd check-config && launchctl kickstart -k gui/$(id -u)/local.thumbd
```

---

## Commands

```
thumbd run              the daemon (what the LaunchAgent runs)
thumbd list             show devices, features and button IDs (read-only)
thumbd check-config     validate the config without touching the mouse
thumbd permissions      show and request the permissions
thumbd test-shortcut S  send shortcut S after 3 s, to test it without the mouse
    --debug             log every press, plus every HID++ report in hex
    --config PATH       use another config file
```

---

## How it works

1. **Find the mouse.** IOHIDManager matches Logitech devices that have an HID++ interface:
   direct Bluetooth, or a Unifying/Bolt receiver.
2. **Divert the buttons.** Feature `REPROG_CONTROLS_V4` (`0x1B04`) tells the mouse to send
   the button presses to thumbd instead of macOS. With gestures configured it also sends the
   movement while the button is held (raw XY).
3. **Turn events into shortcuts.** A small state machine decides between tap and swipe.
   `CGEvent` then posts the keystroke.

Diversion doesn't survive the mouse turning off, so thumbd applies it again whenever:

- the mouse reconnects,
- the receiver reports a connection, or
- the mouse reports it restarted.

Every 60 s, and right after the Mac wakes up, it also checks that the buttons are still
diverted. If they aren't, it fixes them.

When thumbd stops, the buttons get their normal behavior back.

<details>
<summary><b>Reliability details</b></summary>

- **Health check:** one HID++ query per mouse every 60 s, plus 3 s and 15 s after wake.
  Devices whose setup failed are retried by the same check.
- **Single instance:** a lock in `~/Library/Caches/thumbd.lock`. A second `thumbd run` exits
  (code 75) instead of firing every shortcut twice.
- **Permissions first:** if a permission is missing, nothing is diverted and thumbd exits.
  launchd restarts it every ~10 s until both are granted.
- **Quiet log:** only connections, fixes and errors are logged; presses appear only with
  `--debug`. The log is emptied at startup if it's over 5 MB.
- **fn flag:** F-keys, arrows and navigation keys are sent with the fn flag, like a real
  keyboard. Without it, system shortcuts (System Settings → Keyboard) wouldn't match.
- **LaunchAgent:** `RunAtLoad` (start at login) and `KeepAlive` on failure.

</details>

<details>
<summary><b>Protocol notes (HID++ 2.0)</b></summary>

- Long report `0x11`, 20 bytes: `[0x11][devIndex][featureIndex][(func << 4) | swID][params…]`.
  `devIndex` is `0xFF` direct and `1`–`6` behind a receiver. thumbd uses `swID = 1`; events
  from the mouse carry `0`.
- Feature indexes come from ROOT.getFeature (index 0, fn 0) and are never hardcoded.
- `setCidReporting` (fn 3): `CID`, flags, remap `0x0000`.
  - Flags: bit0 divert, bit1 valid, bit4 rawXY, bit5 valid.
  - `0x03` = divert, `0x33` = divert + rawXY, `0x22` = undo.
- Events: fn 0 = pressed CIDs (empty = released); fn 1 = `dx`, `dy` as big-endian int16.
- The Unifying/Bolt receiver path follows Solaar but hasn't been tested with hardware.

</details>

---

## Code signing & Santa

**Why signing matters.** macOS ties permissions to the binary's code signature. With an
ad-hoc signature that's a hash of the binary, so every rebuild silently loses the
permissions. The switch stays on in Settings, but it no longer applies. Sign with a stable
identity and they survive rebuilds:

```sh
export THUMBD_SIGN_IDENTITY=<SHA-1 or name>   # security find-identity -v -p codesigning
# or: export THUMBD_TEAM_ID=<Team ID>         # picks a valid cert from that team
```

`build.sh` and `install.sh` read these variables. Without them they fall back to a
self-signed `thumbd-signing` certificate if you have one, and to ad-hoc otherwise.

**Santa (managed Macs).** In Lockdown mode Santa kills unknown binaries (exit 137). That
includes the one SwiftPM builds from `Package.swift`. To get around it:

- Build with `--swiftc`, which only compiles and never runs anything.
- Ask IT for a rule. Check what Santa will decide with `santactl fileinfo ~/.local/bin/thumbd`.

| Rule type | Covers | Catch |
|---|---|---|
| **SigningID** `TEAMID:carlosfontes.thumbd` | Every future build | Needs a **Developer ID** certificate. Santa ignores this rule for Apple Development certs. |
| **Certificate** (leaf SHA-256) | Anything signed with that cert | Needs a new rule when the cert is renewed. |
| CDHash | One build | A new rule for every rebuild. |

---

## Development

```sh
./scripts/build.sh [--swiftc]   # release build + sign; prints the binary path
./scripts/test.sh  [--swiftc]   # unit tests: gestures, shortcut parsing, config
./scripts/uninstall.sh          # remove the agent and the binary (keeps config and log)
```

| Module | Role |
|---|---|
| `HIDTransport` | IOHIDManager on its own thread; send/receive reports |
| `HIDPP` | HID++ requests, features, `REPROG_CONTROLS_V4`, device discovery |
| `Gestures` | Tap/swipe state machine |
| `Actions` | Shortcut parsing and `CGEvent` posting |
| `Config` | `config.json` decoding and validation |
| `Diagnostics` | Logging and `--debug` hex dumps |
| `thumbd` | CLI, daemon, health check, permissions |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing happens, log says `Missing permission(s)` | Grant Input Monitoring and Accessibility to `~/.local/bin/thumbd`. |
| Permission is on, but still "missing" after a rebuild | Ad-hoc signature. Remove the entry with `−`, add it again, and sign with a stable identity. |
| Mac beeps when the shortcut fires | Nothing is bound to that shortcut, or the app in front doesn't handle it. |
| `Killed: 9` / exit 137 | Santa is blocking the binary. See [Code signing & Santa](#code-signing--santa). |
| `thumbd is already running` | Another instance is active. Stop it, or `launchctl bootout gui/$(id -u)/local.thumbd`. |
| Config change has no effect | Restart: `launchctl kickstart -k gui/$(id -u)/local.thumbd`. |
| Something else | Run `launchctl bootout gui/$(id -u)/local.thumbd`, then `thumbd run --debug` and watch what arrives. |

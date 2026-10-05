# thumbd

A minimal macOS daemon that makes the gesture (thumb) button on the Logitech MX Master 3
work without Logi Options+. It asks the mouse over HID++ 2.0 to **divert** the button
(CID `0x00C3`) and turns presses into configurable keyboard shortcuts (e.g. `⌃⌥⌘F1` for
Raycast).

It's written in Swift with no dependencies beyond IOKit and CoreGraphics. Both phases have been
tested with an MX Master 3 over Bluetooth LE:

- **Tap**: press and release the thumb button → shortcut.
- **Gestures**: hold the thumb button and move up/down/left/right → one shortcut per direction.
- **Extra buttons**: other divertable buttons (e.g. the one below the wheel) → shortcut.

## Structure

| Module         | What it does |
|----------------|--------------|
| `Diagnostics`  | Logging and hex dumps (`--debug`) |
| `HIDTransport` | `IOHIDManager` on its own thread: matching by VID `0x046D` + usage page `0xFF00`/`0xFF43`, sending (`IOHIDDeviceSetReport`) and receiving reports |
| `HIDPP`        | HID++ reports (`0x10`/`0x11`), synchronous request/response, ROOT, FEATURE_SET, DEVICE_NAME, REPROG_CONTROLS_V4, direct/receiver discovery |
| `Gestures`     | Button state machine (no system dependencies) |
| `Actions`      | Shortcut parsing and `CGEvent` keyDown/keyUp |
| `Config`       | `~/.config/thumbd/config.json` |
| `thumbd`       | CLI, daemon, health check, permissions |
| `Tests/thumbd-tests` | Unit tests for `Gestures`, `Actions` and `Config` |

## Building

```sh
swift build -c release            # or: ./scripts/build.sh  (build + sign)
```

`./scripts/build.sh --swiftc` builds module by module with plain `swiftc`, bypassing SwiftPM.
Use it on Macs where SwiftPM can't run its manifest binary (see *Santa* below).

Run the unit tests with `./scripts/test.sh` (or `--swiftc`). They cover the gesture state
machine, shortcut parsing and config decoding, and don't touch the mouse. They're a plain
executable rather than XCTest, because `swift test` needs the SwiftPM manifest.

## Commands

```
thumbd [run]              daemon (default)
thumbd list               devices, features and CIDs (read-only, changes nothing)
thumbd check-config       validates the config without touching the mouse
thumbd permissions        permission status, and prompts to grant them
thumbd test-shortcut [S]  sends shortcut S (or the "tap" one) after 3 s
  --debug                 log every action, plus a hex dump of every HID++ report (→ sent, ← received)
  --config PATH
```

## Configuration

`~/.config/thumbd/config.json` (created on the first `run`). Example:

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

- `tap`: shortcut sent when you press and release without moving. It's written as
  modifiers + key:
  - modifiers: `ctrl`, `alt`/`opt`, `cmd`, `shift`, `fn`
  - keys: `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `return`, `tab`, `esc`, arrows…
  - `⌃⌥⌘F1` style also works.
- `gestures`: shortcuts for **holding the button and moving** (`up`, `down`, `left`,
  `right`). You can leave directions out.
  - With at least one gesture, the button is diverted with rawXY (`0x33`). While it's held,
    the mouse sends its movement to thumbd and **the cursor doesn't move**.
  - With no gestures, it's a plain divert (`0x03`).
- `threshold`: distance after which movement counts as a gesture. It's measured in raw sensor
  units, not screen pixels; at 1000 DPI, 50 ≈ 1.3 mm.
- `button`: CID of the gesture button (from `thumbd list`).
- `buttons`: other divertable buttons (CID → shortcut).
  - They fire **on press** and have no gestures.
  - A diverted button loses its native function. With `0x00C4` (Smart Shift, the button
    below the wheel) the button no longer toggles between ratchet and free-spin. Automatic
    speed-based shifting keeps working.
- `devices`: names (or part of them) as shown by `list`. Empty = any device that has the
  CID and can divert it.

How gestures fire:

- A gesture fires **as soon as the threshold is crossed**, along the dominant axis, once per
  press.
- If the threshold isn't crossed, `tap` fires on release.
- Config changes take effect when thumbd restarts. Validate first, so a typo doesn't leave
  the agent crash-looping:

  ```sh
  thumbd check-config && launchctl kickstart -k gui/$(id -u)/local.thumbd
  ```

  `check-config` also warns about unknown keys (e.g. `"gesture"` instead of `"gestures"`).
  The JSON decoder would otherwise ignore them silently.

**The fn flag.** F-keys, arrows and navigation keys (Home/End/Page Up/Page Down/Forward
Delete) are always sent with the fn flag, like a real keyboard does. macOS stores that flag in
system shortcuts (e.g. ⌃⌥⌘F1 = `0x9C0000`, ⌃← = `0x840000`). Without it they wouldn't match
shortcuts set in System Settings → Keyboard, and the app would just beep.

## Reliability

- **Health check.** Every 60 s thumbd asks each mouse whether the button is still diverted
  (one HID++ request). If not, it diverts it again. The same check runs 3 s and 15 s after
  the Mac wakes up. This covers the cases where the mouse loses its configuration without
  sending any signal.
- **Retries.** A device whose setup failed (e.g. it didn't answer right after connecting)
  is retried by the same check, instead of being given up on.
- **Single instance.** `run` takes a lock (`~/Library/Caches/thumbd.lock`). A second
  instance exits with code 75 instead of firing every shortcut twice. Under launchd it keeps
  retrying, so the agent takes over once the other instance quits.
- **Quiet log.** Normal operation only logs connections, diversions, fixes and errors.
  Individual presses and gestures appear only with `--debug`. On startup the log is
  emptied if it has grown past 5 MB.
- **Clean exit.** On SIGTERM/SIGINT the buttons get their native behavior back.

## Permissions

| Permission | What for | API |
|---|---|---|
| **Input Monitoring** | Opening the mouse with `IOHIDManager`. Over BLE the MX Master 3 is a single HID device that includes a keyboard collection, so macOS protects it | `IOHIDCheckAccess` / `IOHIDRequestAccess` |
| **Accessibility** | Posting keystrokes with `CGEventPost`. Without it macOS drops them **silently** | `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` |

Both are granted to the **responsible process**:

- If you start `thumbd` from a terminal, the permission belongs to **the terminal app**
  (Terminal, iTerm, Warp, Ghostty…), not to the binary.
- If launchd starts it (LaunchAgent), the permission belongs to **the binary itself**
  (`~/.local/bin/thumbd`).

`thumbd permissions` shows the prompts. If they don't appear (because the permission was
denied before), add it by hand:

1. Open System Settings → Privacy & Security → *Input Monitoring* (or *Accessibility*).
2. Click `+` and pick the binary (⌘⇧G to type the path) or the terminal app.

macOS doesn't tell a running process that a permission was granted. So if either
permission is missing, `run` diverts nothing and exits (code 75). Under launchd it restarts
within ~10 s and picks up the new permission on its own. From a terminal, run it again.

## Code signing, and why ad-hoc isn't enough

On Apple Silicon every binary must be signed. The linker already adds an ad-hoc signature,
and `build.sh` redoes it with a stable identifier. TCC (the permissions database) doesn't store
"this name", though. It stores the binary's **designated requirement**, and for an ad-hoc
signature that requirement is its hash:

```
$ codesign -d -r- .build/release/thumbd
# designated => cdhash H"0738045422a4fb45d6ee29ef1a412b7d6bb26fed"
```

Every rebuild changes the cdhash. The switch in System Settings still shows as **on**, but it
no longer applies to the new binary: the classic "I granted it and it doesn't work". You
have to remove it with `−` and add it again.

For permissions to survive rebuilds you need a **stable signing identity**:

- **Apple certificate** (Apple Development or Developer ID). The requirement becomes
  `identifier "…" and anchor apple generic and certificate leaf[subject.CN] = "…" …`. It
  stays the same across rebuilds and certificate renewals.
- **Self-signed certificate** (`identifier "…" and certificate root = H"…"`):
  1. Keychain Access → *Keychain Access* menu → *Certificate Assistant* → *Create a
     Certificate…*
  2. Name it `thumbd-signing`. Identity type: *Self-Signed Root*. Certificate type:
     *Code Signing*.

`build.sh` picks an identity with these variables:

| Variable | Effect |
|---|---|
| `THUMBD_SIGN_IDENTITY` | A specific identity, by name or SHA-1 |
| `THUMBD_TEAM_ID` | The first valid certificate from that team. Developer ID Application is preferred over Apple Development |
| `THUMBD_SIGNING_ID` | The signing identifier (default `carlosfontes.thumbd`) |

With none of them set, it uses `thumbd-signing` if that certificate exists, and ad-hoc
otherwise.

If you only test from the terminal it doesn't matter, because the permission belongs to the
terminal. It matters for the LaunchAgent.

## Santa (managed Macs)

**Symptom.** `swift build` fails with `Invalid manifest … Missing or empty JSON output`, or the
binary dies with `Killed: 9` / exit 137. Run `santactl status`: in **Lockdown** mode Santa
kills any binary without an explicit rule. That includes the temporary executable SwiftPM
compiles from `Package.swift`. It's not a bug in the project.

**Building.** `./scripts/build.sh --swiftc` only compiles and links; it never runs anything.
`swift build` stays blocked, because SwiftPM's manifest binary is ad-hoc.

**Running.** `thumbd` needs an allow rule from IT. Check what Santa sees with
`santactl fileinfo <binary>`. The rule types that matter:

| Rule type | Matches | Notes |
|---|---|---|
| **SigningID** (`TEAMID:identifier`) | Any build with that identifier, signed by that team | Best option. Santa **ignores** it for binaries signed with **Apple Development** ("SigningID rule ignored because code signed with a development certificate"). It needs a **Developer ID Application** certificate, which only the Account Holder or an Admin of the Apple Developer account can issue. |
| **Certificate** (SHA-256 of the leaf certificate) | Anything signed with that certificate | Works with Apple Development. Needs a new rule when the certificate is renewed. If you have several certificates with the same name, pin the allowed one with `THUMBD_SIGN_IDENTITY=<SHA-1>`. |
| CDHash / binary hash | One exact build | Needs a new rule on every rebuild. |

For example:

```sh
export THUMBD_SIGN_IDENTITY=<SHA-1 of the allowed certificate>   # security find-identity -v -p codesigning
./scripts/build.sh --swiftc
santactl fileinfo .build/swiftc-release/thumbd                   # → Expected Decision: Allowed by rule
```

## Testing step by step

1. **Build**: `./scripts/build.sh` (or `--swiftc`). The last line of output is the binary
   path. In the steps below, `thumbd` means that path.

2. **Terminal permissions**: run `thumbd permissions`. Grant both permissions to your terminal
   app and **restart the terminal**.

3. **List** (read-only): run `thumbd list`. You should see something like:

   ```
   [1] MX Master 3
       VID 0x046D  PID 0xB023  transport: Bluetooth Low Energy  reports: in 20 / out 20 bytes
       collections (page/usage): 0x0001/0x0006 0x0001/0x0002 0x0001/0x0001 0xFF43/0x0202
       ── index 0xFF: "Wireless Mouse MX Master 3"  HID++ 4.5
          features (31):
            0x00  0x0000  ROOT                     v0
            …
            0x09  0x1B04  REPROG_CONTROLS_V4       v4
          REPROG_CONTROLS_V4 controls (index 0x09, 8):
            CID     TID     name                   flags                                        state
            0x00C3  0x00A9  Mouse Gesture Button   mouse reprog divert rawXY analytics          divert=0 rawXY=0
            0x00C4  0x009D  Smart Shift            mouse reprog divert rawXY analytics          divert=0 rawXY=0
   ```

   Check that `0x00C3` shows `divert` and `rawXY` (rawXY is needed for gestures).
   With `--debug` you'll see every exchange, e.g. getFeature(0x1B04):
   `→ 11 FF 00 01 1B 04 …` / `← 11 FF 00 01 09 00 04 …`.

4. **Shortcut without the mouse**: run `thumbd test-shortcut`, focus the hotkey recorder in
   Raycast (or wherever) and wait 3 s. If nothing arrives, Accessibility is missing.

5. **Daemon in the foreground**: run `thumbd run --debug`. It should print something like
   `✓ Wireless Mouse MX Master 3: button 0x00C3 diverted (divert=1 rawXY=1): tap ⌃⌥⌘F1, ↑ ⌃⌥⌘F2, …`.
   Then try each action:

   ```
   ← [B023] 11 FF 09 00 00 C3 00 00 …   pressed   (divertedButtonsEvent, CID 0x00C3)
   ← [B023] 11 FF 09 00 00 00 00 00 …   released  (empty list)
     Wireless Mouse MX Master 3: tap → ⌃⌥⌘F1

   ← [B023] 11 FF 09 10 FF FD 00 00 …   movement while held (divertedRawXYEvent, dx = -3)
     Wireless Mouse MX Master 3: gesture ← → ⌃←
   ```

6. **Clean exit**: Ctrl-C prints "restoring the buttons' original behavior".

7. **Reconnection**: with `run` active, turn the mouse off and on again. You should see
   "disconnected", then `✓ … diverted` again when it comes back.

8. **LaunchAgent**: `./scripts/install.sh` (also accepts `--swiftc`).
   - It installs `~/.local/bin/thumbd` and `~/Library/LaunchAgents/local.thumbd.plist`.
   - The agent uses `RunAtLoad` and `KeepAlive` with `SuccessfulExit=false`, so it restarts if
     it fails but not when you stop it.
   - Grant both permissions to the **binary** `~/.local/bin/thumbd`.
   - Follow the log with `tail -f ~/Library/Logs/thumbd.log`.
   - Uninstall with `./scripts/uninstall.sh`.

## Protocol details

- Long report `0x11`, 20 bytes: `[0x11][devIndex][featureIndex][(func << 4) | swID][params…]`.
  - `devIndex` is `0xFF` for a direct connection and `1`–`6` behind a receiver.
  - `swID = 0x1` for our requests; mouse events carry `0`.
- Errors: 2.0 `[.. 0xFF featIdx func|sw code]`, 1.0 `[.. 0x8F subID addr code]`.
- Feature indexes come from ROOT.getFeature (index 0, function 0); they're never assumed.
- REPROG_CONTROLS_V4 (`0x1B04`): fn0 getCount, fn1 getCidInfo, fn2 getCidReporting,
  fn3 setCidReporting(`CID`, flags, remap `0x0000`).
  - Flags: bit0 divert, bit1 valid, bit4 rawXY, bit5 valid.
  - Divert = `0x03`, divert + rawXY = `0x33`, undo = `0x22`.
- Events: fn0 divertedButtons (up to 4 BE CIDs; empty = released), fn1 divertedRawXY
  (dx, dy as BE int16, positive y = down).
- Diversion isn't persistent. It's applied again when:
  - the IOHIDDevice appears (IOHIDManager matching),
  - the receiver reports a connection (`0x41`),
  - the mouse sends WIRELESS_DEVICE_STATUS (`0x1D4B`).
- **Unifying/Bolt receiver**: implemented following Solaar, but **not tested with
  hardware**. It pings indexes 1–6, sets the wireless notifications flag in register `0x00`
  and listens for `0x41`.

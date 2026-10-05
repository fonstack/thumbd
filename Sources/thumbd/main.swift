import Actions
import Config
import Diagnostics
import Foundation

let usage = """
usage: thumbd [command] [--debug] [--config PATH]

commands:
  run                 (default) daemon: diverts the buttons and fires the shortcuts
  list                lists devices, features and CIDs (read-only)
  check-config        validates the config file without touching the mouse
  permissions         shows and requests the required permissions
  test-shortcut [S]   fires shortcut S (or the "tap" one) after 3 s, no mouse needed

options:
  --debug             logs every action, and every HID++ report sent (→) and received (←) in hex
  --config PATH       alternative config (default ~/.config/thumbd/config.json)
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var configURL = Config.defaultPath
if let i = arguments.firstIndex(of: "--config") {
    guard i + 1 < arguments.count else { print(usage); exit(64) }
    configURL = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath)
    arguments.removeSubrange(i...(i + 1))
}
if let i = arguments.firstIndex(of: "--debug") {
    Log.debugEnabled = true
    arguments.remove(at: i)
}
let command = arguments.first ?? "run"
let commandArgs = Array(arguments.dropFirst())
let agentTarget = "gui/\(getuid())/local.thumbd"

func loadConfig() -> Config {
    do {
        let loaded = try Config.load(from: configURL)
        if loaded.created { Log.info("Created default config at \(configURL.path)") }
        for key in loaded.unknownKeys { Log.warn("Config: unknown key \"\(key)\" is ignored (typo?)") }
        return loaded.config
    } catch {
        Log.error("Config \(configURL.path): \(describeConfigError(error))")
        exit(78)
    }
}

/// Both permissions are required before diverting anything: without Accessibility the
/// buttons would lose their native function and the shortcuts would go nowhere.
/// macOS doesn't tell a running process that a permission was granted, so instead of waiting
/// in-process we exit: launchd (KeepAlive) starts a fresh process, which sees the new state.
func requirePermissions() {
    if Permissions.inputMonitoring != .granted { Permissions.requestInputMonitoring() }
    if Permissions.postEvents != .granted { Permissions.requestPostEvents() }
    var missing: [String] = []
    if Permissions.inputMonitoring != .granted { missing.append("Input Monitoring") }
    if Permissions.postEvents != .granted { missing.append("Accessibility") }
    guard !missing.isEmpty else { return }
    let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
    Log.warn("Missing permission(s) for \(binary): \(missing.joined(separator: ", ")).")
    Log.warn("Grant them in System Settings → Privacy & Security, then thumbd must restart.")
    Log.warn("Exiting; under launchd it restarts in ~10 s (from a terminal, run it again).")
    exit(75) // EX_TEMPFAIL: KeepAlive restarts it
}

setvbuf(stdout, nil, _IOLBF, 0)

switch command {
case "run":
    Log.trimLogFileIfNeeded()
    let config = loadConfig()
    let bindings: Bindings
    do {
        bindings = try Bindings(config: config)
    } catch {
        Log.error("Config \(configURL.path): \(error)")
        exit(78)
    }
    if case .heldBy(let pid) = InstanceLock.acquire() {
        Log.warn("thumbd is already running\(pid.map { " (pid \($0))" } ?? ""); a second instance would fire every shortcut twice.")
        Log.warn("Stop the other one first (the LaunchAgent: launchctl bootout \(agentTarget)). Exiting.")
        exit(75) // under launchd: retry later, so the agent takes over once the other one quits
    }
    requirePermissions()
    Daemon(config: config, bindings: bindings).run()

case "check-config":
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        print("\(configURL.path) doesn't exist; `thumbd run` will create it with the defaults.")
        exit(0)
    }
    do {
        let loaded = try Config.load(from: configURL)
        for key in loaded.unknownKeys { print("! unknown key \"\(key)\" is ignored (typo?)") }
        let bindings = try Bindings(config: loaded.config)
        print("✓ \(configURL.path)")
        print("  button \(hex16(loaded.config.button)): \(bindings.summary)")
        print("  threshold \(loaded.config.threshold)")
        if !loaded.config.devices.isEmpty {
            print("  devices: \(loaded.config.devices.joined(separator: ", "))")
        }
        print("Apply it with: launchctl kickstart -k \(agentTarget)")
    } catch {
        print("✗ \(configURL.path): \(describeConfigError(error))")
        exit(78)
    }

case "list":
    if Permissions.inputMonitoring != .granted { Permissions.requestInputMonitoring() }
    exit(ListCommand.run())

case "permissions":
    print("Input Monitoring: \(Permissions.inputMonitoring.rawValue)")
    print("Accessibility (post events): \(Permissions.postEvents.rawValue)")
    if Permissions.inputMonitoring != .granted { Permissions.requestInputMonitoring() }
    if Permissions.postEvents != .granted { Permissions.requestPostEvents() }
    if Permissions.inputMonitoring != .granted || Permissions.postEvents != .granted {
        print("\nIf no prompt appeared, add it by hand:")
        print("  open \"\(Permissions.inputMonitoringPane)\"")
        print("  open \"\(Permissions.accessibilityPane)\"")
    }

case "test-shortcut":
    let text = commandArgs.first ?? loadConfig().tap
    do {
        let shortcut = try KeyShortcut(text)
        if Permissions.postEvents != .granted {
            Permissions.requestPostEvents()
            print("Warning: without the Accessibility permission the shortcut won't arrive.")
        }
        print("Sending \(shortcut) in 3 s…")
        Thread.sleep(forTimeInterval: 3)
        shortcut.post()
        print("Sent.")
    } catch {
        print("Shortcut \"\(text)\": \(error)")
        exit(65)
    }

case "help", "-h", "--help":
    print(usage)

default:
    print(usage)
    exit(64)
}

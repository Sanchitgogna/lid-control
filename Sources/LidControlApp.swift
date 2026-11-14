import SwiftUI
import AppKit
import Carbon.HIToolbox
import IOKit
import IOKit.ps
import ServiceManagement

// MARK: - App

@main
struct LidControlApp: App {
    @StateObject private var power = PowerController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(power)
        } label: {
            Image(systemName: power.sleepDisabled ? "cup.and.saucer.fill" : "laptopcomputer")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Shell helpers

enum Shell {
    /// Runs a command without privileges and returns stdout.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        runWithStatus(path, args).output
    }

    static func runWithStatus(_ path: String, _ args: [String]) -> (output: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    /// Runs AppleScript source. Returns an error message, or nil on success.
    static func appleScript(_ source: String) -> String? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "Could not build script." }
        script.executeAndReturnError(&err)
        guard let err else { return nil }
        // -128 = user cancelled the password prompt / dialog
        if (err[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return (err[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error."
    }

    /// Runs a shell command as root. macOS shows its standard admin password prompt.
    static func admin(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return appleScript("do shell script \"\(escaped)\" with administrator privileges")
    }
}

// MARK: - System readings

enum SystemInfo {
    struct Battery { let percent: Int; let onBattery: Bool }

    /// Internal battery state, or nil on Macs without a battery.
    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = d[kIOPSPowerSourceStateKey] as? String
            return Battery(percent: max > 0 ? current * 100 / max : current,
                           onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }

    /// True when the laptop lid is shut.
    static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static var isHot: Bool {
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical
    }

    /// Reads "SleepDisabled" from `pmset -g`.
    static var sleepDisabled: Bool {
        Shell.run("/usr/bin/pmset", ["-g"]).split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count >= 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }
}

// MARK: - Updates

enum Updates {
    static let repo = "Sanchitgogna/lid-control"
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    /// Latest release on GitHub, as (version, page URL).
    static func latest() async throws -> (version: String, url: URL) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        let r = try JSONDecoder().decode(Release.self, from: data)
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return (version, URL(string: r.html_url) ?? URL(string: "https://github.com/\(repo)/releases")!)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - Password-free access

/// Optional one-time setup: a sudoers rule that lets *this user* run only the
/// specific pmset commands the app needs, without a password. Nothing else.
enum PasswordFree {
    static let rulePath = "/etc/sudoers.d/lidcontrol"
    static let pmset = "/usr/bin/pmset"

    /// True if the rule is installed and working.
    static var isEnabled: Bool {
        Shell.runWithStatus("/usr/bin/sudo", ["-n", "-l", pmset, "-a", "disablesleep", "1"]).status == 0
    }

    /// Runs pmset as root without a prompt. Returns false if not allowed.
    static func run(_ args: [String]) -> Bool {
        Shell.runWithStatus("/usr/bin/sudo", ["-n", pmset] + args).status == 0
    }

    /// Installs the rule (asks for the admin password this one time).
    static func install() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return "Your account name has unusual characters, so this can't be set up automatically."
        }
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1, \(pmset) repeat *"
        let cmd = "T=$(/usr/bin/mktemp) && printf '%s\\n' '\(rule)' > \"$T\" && /usr/sbin/visudo -cf \"$T\" >/dev/null && /usr/bin/install -m 0440 -o root -g wheel \"$T\" \(rulePath) && /bin/rm -f \"$T\""
        return Shell.admin(cmd)
    }

    static func remove() -> String? {
        Shell.admin("/bin/rm -f \(rulePath)")
    }
}

// MARK: - Global keyboard shortcut

/// A system-wide hotkey via Carbon's RegisterEventHotKey.
/// Works from any app and needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4C49_4443), id: 1) // 'LIDC'
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - On-screen confirmation (like the volume overlay)

@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(symbol: String, title: String, subtitle: String) {
        let size = NSSize(width: 240, height: 170)
        let host = NSHostingView(rootView: HUDView(symbol: symbol, title: title, subtitle: subtitle))
        host.frame = NSRect(origin: .zero, size: size)

        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = p
        }
        p.contentView = host
        p.setContentSize(size)
        if let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 120))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

struct HUDView: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 46, weight: .medium))
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(18)
        .frame(width: 240, height: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Power controller

@MainActor
final class PowerController: ObservableObject {
    @Published var sleepDisabled = false
    @Published var scheduleSummary = ""
    @Published var message: String?
    @Published var passwordFree = false
    @Published var shortcutEnabled = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shortcutEnabled, forKey: "shortcutEnabled")
            updateHotKey()
        }
    }

    // Safety cut-off for "Stay on"
    @Published var safetyEnabled = UserDefaults.standard.object(forKey: "safetyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(safetyEnabled, forKey: "safetyEnabled") }
    }
    @Published var batteryLimit = UserDefaults.standard.object(forKey: "batteryLimit") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(batteryLimit, forKey: "batteryLimit") }
    }
    static let batteryLimitChoices = [10, 15, 20, 30]
    private var warnedSafetyNeedsPermission = false

    // Start at login
    @Published var startAtLogin = SMAppService.mainApp.status == .enabled

    // Updates
    @Published var availableUpdate: String?
    @Published var updateURL: URL?
    private var lastUpdateCheck = Date.distantPast

    /// Shown in the UI. Keep in sync with updateHotKey().
    static let shortcutLabel = "⌥⌘L"
    private var hotKey: HotKey?
    private var pollTask: Task<Void, Never>?

    init() {
        refresh()
        updateHotKey()

        // Remind the user if "Stay on" was left on (e.g. after quitting or restarting).
        if sleepDisabled {
            message = "Heads up: “Stay on” was already ON when Lid Control started."
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                HUD.show(symbol: "cup.and.saucer.fill", title: "Stay on is still ON",
                         subtitle: "Your Mac won't sleep when the lid closes")
            }
        }

        // Every 5 s: keep the icon in sync and run the safety check.
        // Once a day: look for a new version.
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func tick() {
        let current = SystemInfo.sleepDisabled
        if current != sleepDisabled { sleepDisabled = current }
        if !sleepDisabled { warnedSafetyNeedsPermission = false }
        safetyCheck()
        if Date().timeIntervalSince(lastUpdateCheck) > 24 * 60 * 60 {
            lastUpdateCheck = Date()
            Task { await checkForUpdates(userInitiated: false) }
        }
    }

    // MARK: Safety cut-off

    /// Turns "Stay on" off when the battery is low or the Mac is hot,
    /// then sleeps the Mac if the lid is closed.
    private func safetyCheck() {
        guard safetyEnabled, sleepDisabled else { return }

        let reason: String
        if SystemInfo.isHot {
            reason = "Your Mac was getting hot"
        } else if let b = SystemInfo.battery(), b.onBattery, b.percent <= batteryLimit {
            reason = "Battery was at \(b.percent)%"
        } else {
            return
        }

        // Must work unattended, so it can't show a password prompt.
        guard passwordFree, PasswordFree.run(["-a", "disablesleep", "0"]) else {
            if !warnedSafetyNeedsPermission {
                warnedSafetyNeedsPermission = true
                message = "\(reason). Turn on “Don't ask for my password” so Lid Control can switch “Stay on” off by itself."
                HUD.show(symbol: "exclamationmark.triangle.fill", title: "Turn off “Stay on”",
                         subtitle: reason)
            }
            return
        }

        sleepDisabled = SystemInfo.sleepDisabled
        message = "“Stay on” was turned off automatically. \(reason)."
        HUD.show(symbol: "exclamationmark.triangle.fill", title: "Stay on turned OFF", subtitle: reason)
        if SystemInfo.lidClosed {
            Shell.run("/usr/bin/pmset", ["sleepnow"])
        }
    }

    // MARK: Start at login

    func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Start at login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        startAtLogin = status == .enabled
        if status == .requiresApproval {
            message = "Allow Lid Control in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: Updates

    func checkForUpdates(userInitiated: Bool) async {
        lastUpdateCheck = Date()
        do {
            let latest = try await Updates.latest()
            if Updates.isNewer(latest.version, than: Updates.currentVersion) {
                availableUpdate = latest.version
                updateURL = latest.url
            } else {
                availableUpdate = nil
                if userInitiated { message = "You're up to date (version \(Updates.currentVersion))." }
            }
        } catch {
            if userInitiated { message = "Couldn't check for updates. Are you online?" }
        }
    }

    func openUpdate() {
        if let updateURL { NSWorkspace.shared.open(updateURL) }
    }

    // MARK: Quit

    /// Warns before quitting while "Stay on" is still active.
    func quit() {
        if sleepDisabled {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "“Stay on when lid is closed” is still ON"
            alert.informativeText = "If you quit, your Mac will keep running with the lid closed and there'll be no menu bar icon to remind you."
            alert.addButton(withTitle: "Turn Off and Quit")
            alert.addButton(withTitle: "Keep On and Quit")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                setStayAwakeWithLidClosed(false)
                if sleepDisabled { return } // password cancelled — don't quit
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        NSApp.terminate(nil)
    }

    private func updateHotKey() {
        guard shortcutEnabled else { hotKey = nil; return }
        guard hotKey == nil else { return }
        hotKey = HotKey(keyCode: kVK_ANSI_L, modifiers: cmdKey | optionKey) { [weak self] in
            Task { @MainActor in self?.toggleLidFromShortcut() }
        }
        if hotKey == nil {
            message = "\(Self.shortcutLabel) is already used by another app."
        }
    }

    /// Flips "Stay on when lid is closed" and shows an on-screen confirmation.
    func toggleLidFromShortcut() {
        let before = sleepDisabled
        setStayAwakeWithLidClosed(!before)
        guard sleepDisabled != before else { return } // cancelled or failed
        if sleepDisabled {
            HUD.show(symbol: "cup.and.saucer.fill", title: "Stay on: ON",
                     subtitle: "Mac keeps running with the lid closed")
        } else {
            HUD.show(symbol: "moon.fill", title: "Stay on: OFF",
                     subtitle: "Mac sleeps when the lid closes")
        }
    }

    /// Runs pmset as root: silently if password-free access is set up,
    /// otherwise via the normal macOS password prompt. Returns an error or nil.
    private func pmsetAsRoot(_ args: [String]) -> String? {
        if passwordFree && PasswordFree.run(args) { return nil }
        return Shell.admin(([PasswordFree.pmset] + args).joined(separator: " "))
    }

    func setPasswordFree(_ on: Bool) {
        let err = on ? PasswordFree.install() : PasswordFree.remove()
        passwordFree = PasswordFree.isEnabled
        if let err { message = err }
        else { message = passwordFree ? "Done — no more password prompts." : "Password prompts turned back on." }
    }

    func refresh() {
        passwordFree = PasswordFree.isEnabled
        sleepDisabled = SystemInfo.sleepDisabled
        startAtLogin = SMAppService.mainApp.status == .enabled

        let sched = Shell.run("/usr/bin/pmset", ["-g", "sched"])
        let lines = sched.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        scheduleSummary = lines.isEmpty ? "No schedule set." : lines.joined(separator: "\n")
    }

    // Lid-closed behaviour

    func setStayAwakeWithLidClosed(_ on: Bool) {
        if let err = pmsetAsRoot(["-a", "disablesleep", on ? "1" : "0"]) {
            message = err
        } else {
            message = on
                ? "Your Mac will stay on when the lid is closed."
                : "Your Mac will sleep when the lid is closed (normal behaviour)."
        }
        refresh()
    }

    // Immediate actions

    func sleepNow() {
        Shell.run("/usr/bin/pmset", ["sleepnow"])
    }

    func lockScreen() {
        // Sleeping the display locks the Mac if "require password" is on.
        Shell.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func restart() {
        guard confirm("Restart your Mac?", button: "Restart") else { return }
        message = Shell.appleScript("tell application \"System Events\" to restart")
    }

    func shutDown() {
        guard confirm("Shut down your Mac?", button: "Shut Down") else { return }
        message = Shell.appleScript("tell application \"System Events\" to shut down")
    }

    // Scheduled power on / off

    func applySchedule(powerOn: Bool, onTime: Date,
                       powerOff: Bool, offTime: Date,
                       days: Set<Weekday>) {
        guard powerOn || powerOff else { cancelSchedule(); return }
        guard !days.isEmpty else { message = "Pick at least one day."; return }

        let dayString = Weekday.allCases.filter { days.contains($0) }.map(\.pmsetLetter).joined()
        var args = ["repeat"]
        if powerOn  { args += ["wakeorpoweron", dayString, Self.pmsetTime(onTime)] }
        if powerOff { args += ["shutdown", dayString, Self.pmsetTime(offTime)] }

        if let err = pmsetAsRoot(args) { message = err } else { message = "Schedule saved." }
        refresh()
    }

    func cancelSchedule() {
        if let err = pmsetAsRoot(["repeat", "cancel"]) { message = err } else { message = "Schedule cleared." }
        refresh()
    }

    // Helpers

    private static func pmsetTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func confirm(_ text: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = "Unsaved work in open apps may ask you to save first."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum Weekday: Int, CaseIterable, Hashable {
    case mon, tue, wed, thu, fri, sat, sun

    var pmsetLetter: String { ["M", "T", "W", "R", "F", "S", "U"][rawValue] }
    var short: String { ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"][rawValue] }
}

// MARK: - UI

struct MenuContent: View {
    @EnvironmentObject var power: PowerController

    @AppStorage("schedOn") private var schedOn = false
    @AppStorage("schedOff") private var schedOff = false
    @AppStorage("onTime") private var onTimeInterval: Double = PowerDefaults.time(hour: 8)
    @AppStorage("offTime") private var offTimeInterval: Double = PowerDefaults.time(hour: 23)
    @AppStorage("days") private var daysRaw = "0,1,2,3,4"

    private var days: Set<Weekday> {
        Set(daysRaw.split(separator: ",").compactMap { Int($0) }.compactMap(Weekday.init(rawValue:)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Lid Control").font(.headline)
                Spacer()
                Button { power.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh status")
            }

            // Lid
            GroupBox {
                Toggle(isOn: Binding(
                    get: { power.sleepDisabled },
                    set: { power.setStayAwakeWithLidClosed($0) })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stay on when lid is closed")
                        Text(power.sleepDisabled
                             ? "ON — Mac keeps running with the lid shut. Don't put it in a bag."
                             : "OFF — Mac sleeps when the lid is shut (normal).")
                            .font(.caption)
                            .foregroundStyle(power.sleepDisabled ? .orange : .secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(4)

                HStack {
                    Toggle("Keyboard shortcut", isOn: $power.shortcutEnabled)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Text(PowerController.shortcutLabel)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .opacity(power.shortcutEnabled ? 1 : 0.4)
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Toggle("Safety cut-off below", isOn: $power.safetyEnabled)
                            .toggleStyle(.checkbox)
                        Spacer()
                        Picker("", selection: $power.batteryLimit) {
                            ForEach(PowerController.batteryLimitChoices, id: \.self) { Text("\($0)%").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!power.safetyEnabled)
                    }
                    Text(power.safetyEnabled && !power.passwordFree
                         ? "Needs “Don't ask for my password” to work."
                         : "Turns “Stay on” off on low battery or if the Mac gets hot.")
                        .font(.caption)
                        .foregroundStyle(power.safetyEnabled && !power.passwordFree ? .orange : .secondary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            } label: { Label("Lid", systemImage: "laptopcomputer") }

            // Power now
            GroupBox {
                HStack {
                    Button { power.sleepNow() } label: { Label("Sleep", systemImage: "moon.fill") }
                    Button { power.lockScreen() } label: { Label("Screen off", systemImage: "display") }
                }
                HStack {
                    Button { power.restart() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    Button(role: .destructive) { power.shutDown() } label: { Label("Shut Down", systemImage: "power") }
                }
            } label: { Label("Power now", systemImage: "bolt.fill") }

            // Schedule
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Turn on at", isOn: $schedOn)
                        Spacer()
                        DatePicker("", selection: dateBinding($onTimeInterval), displayedComponents: .hourAndMinute)
                            .labelsHidden().disabled(!schedOn)
                    }
                    HStack {
                        Toggle("Shut down at", isOn: $schedOff)
                        Spacer()
                        DatePicker("", selection: dateBinding($offTimeInterval), displayedComponents: .hourAndMinute)
                            .labelsHidden().disabled(!schedOff)
                    }
                    HStack(spacing: 4) {
                        ForEach(Weekday.allCases, id: \.self) { day in
                            Toggle(day.short, isOn: dayBinding(day))
                                .toggleStyle(.button)
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("Save schedule") {
                            power.applySchedule(
                                powerOn: schedOn, onTime: Date(timeIntervalSinceReferenceDate: onTimeInterval),
                                powerOff: schedOff, offTime: Date(timeIntervalSinceReferenceDate: offTimeInterval),
                                days: days)
                        }
                        Button("Clear") { power.cancelSchedule() }
                    }
                    Text("On Apple Silicon Macs, “Turn on” wakes the Mac from sleep but can't start it from fully shut down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(power.scheduleSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            } label: { Label("Schedule", systemImage: "calendar") }

            // Password
            GroupBox {
                Toggle(isOn: Binding(
                    get: { power.passwordFree },
                    set: { power.setPasswordFree($0) })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Don't ask for my password")
                        Text(power.passwordFree
                             ? "Lid and schedule changes apply instantly."
                             : "Enter your password once to stop the prompts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(4)

                Toggle(isOn: Binding(
                    get: { power.startAtLogin },
                    set: { power.setStartAtLogin($0) })
                ) {
                    Text("Start at login")
                }
                .toggleStyle(.switch)
                .padding(4)
            } label: { Label("Settings", systemImage: "gearshape.fill") }

            if let version = power.availableUpdate {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Version \(version) is available")
                    Spacer()
                    Button("Download") { power.openUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(8)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let msg = power.message {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Version \(Updates.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for updates") {
                    Task { await power.checkForUpdates(userInitiated: true) }
                }
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
                Button("Quit") { power.quit() }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { power.refresh() }
    }

    private func dateBinding(_ storage: Binding<Double>) -> Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: storage.wrappedValue) },
            set: { storage.wrappedValue = $0.timeIntervalSinceReferenceDate })
    }

    private func dayBinding(_ day: Weekday) -> Binding<Bool> {
        Binding(
            get: { days.contains(day) },
            set: { on in
                var d = days
                if on { d.insert(day) } else { d.remove(day) }
                daysRaw = d.map { String($0.rawValue) }.sorted().joined(separator: ",")
            })
    }
}

enum PowerDefaults {
    static func time(hour: Int) -> Double {
        let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return d.timeIntervalSinceReferenceDate
    }
}

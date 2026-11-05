// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import BrilhoEngine
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Where Brilho keeps its settings and what it learns: the XDG directories.
public struct Storage: Sendable {
    public var config: URL
    public var state: URL

    public init(config: URL, state: URL) {
        self.config = config
        self.state = state
    }

    public static var standard: Storage {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        let state = environment["XDG_STATE_HOME"] ?? home + "/.local/state"
        return Storage(config: URL(fileURLWithPath: config + "/brilho/config.json"), state: URL(fileURLWithPath: state + "/brilho/state.json"))
    }

    public func loadConfig() -> Config { load(Config.self, from: config) ?? Config() }
    public func loadState() -> State { load(State.self, from: state) ?? State() }
    public func save(_ config: Config) { store(config, at: self.config) }
    public func save(_ state: State) { store(state, at: self.state) }

    /// The settings file's last change, to read it again when it's edited.
    public var configModified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: config.path))?[.modificationDate] as? Date
    }

    private func load<T: Decodable>(_: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Kept aside rather than lost: the next save would write over it
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("unreadable"))
            return nil
        }
    }

    private func store<T: Encodable>(_ value: T, at url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Brilho as a service, `brilho run`: finds the light sensor, the laptop's
/// panel and the monitors, follows the light twenty times a second, looks for
/// monitors coming and going every ten seconds, and answers `brilho` commands.
public final class Service {
    private let paths: Paths
    private let storage: Storage
    private let runner: Runner
    private var engine: Engine?
    private var backlight: Backlight?
    private var monitors: [String: DDCMonitor] = [:]
    private var server: Socket.Server?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var configModified: Date?
    private var lookedAt = Date()
    private var fast = true
    private var logged: Set<String> = []
    private let gnomeAuto: GnomeAutoBrightness

    public init(paths: Paths = .current, storage: Storage = .standard, runner: Runner = .system) {
        self.paths = paths
        self.storage = storage
        self.runner = runner
        gnomeAuto = GnomeAutoBrightness(runner: runner)
    }

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8)) // systemd's journal stamps it
    }

    /// Each problem once, not every ten seconds.
    private func logOnce(_ message: String) {
        if logged.insert(message).inserted { Self.log(message) }
    }

    public func run() -> Never {
        // One at a time: two would fight over the screens
        if Socket.send(["status"]) != nil {
            Self.log("Brilho is already running")
            exit(0)
        }
        let sensor = IIOLight.find(paths)
        backlight = Backlight.find(paths, runner: runner)
        monitors = Dictionary(DDCMonitor.find(paths, log: logOnce).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let x11 = X11Session()
        // GNOME sets the gamma itself, for its Night Light and colour profiles, on X11 too: Brilho drives its Night Light
        let white: WhiteOutput? = GnomeNightLight(runner: runner) ?? x11.flatMap { $0.canSetWhite ? $0 : nil }
        Self.log("Brilho \(brilhoVersion): light sensor \(sensor?.name ?? "none (following the time of day)"), "
            + "panel \(backlight.map { URL(fileURLWithPath: $0.device).lastPathComponent + ($0.writable ? "" : " (through logind)") } ?? "none"), "
            + "\(monitors.count) monitor\(monitors.count == 1 ? "" : "s") over DDC, "
            + "Night Warmth \(white is X11Session ? "through X11" : white is GnomeNightLight ? "through GNOME's Night Light" : "not available on this desktop")")
        configModified = storage.configModified
        let engine = Engine(sensor: sensor, screens: currentScreens(), white: white,
                            surroundings: LinuxSurroundings(paths: paths, runner: runner, x11: x11),
                            config: storage.loadConfig(), state: storage.loadState(),
                            save: { [storage] in storage.save($0) },
                            saveConfig: { [weak self] config in
                                self?.storage.save(config)
                                self?.configModified = self?.storage.configModified
                            },
                            log: Self.log)
        self.engine = engine
        gnomeAuto.turnOff(log: Self.log)

        server = Socket.Server { [weak self] words in self?.engine?.command(words, at: Date()) ?? "" }
        if server == nil { Self.log("couldn't listen on \(Socket.path): brilho commands won't reach this one") }

        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signals.append(source)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        dispatchMain()
    }

    /// Twenty times a second while a screen eases somewhere, twice otherwise, so
    /// a laptop's processor can sleep in between.
    private func tick() {
        guard let engine else { return }
        engine.update(at: Date())
        if engine.easing != fast {
            fast = engine.easing
            timer?.schedule(deadline: .now() + (fast ? 0.05 : 0.5), repeating: fast ? .milliseconds(50) : .milliseconds(500),
                            leeway: fast ? .milliseconds(10) : .milliseconds(100))
        }
        guard Date().timeIntervalSince(lookedAt) >= 10 else { return }
        lookedAt = Date()
        monitors = Dictionary(DDCMonitor.find(paths, existing: monitors, log: logOnce).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let screens = currentScreens()
        if screens.map(\.key) != engine.screens.map(\.key) { engine.setScreens(screens) }
        if let modified = storage.configModified, modified != configModified {
            configModified = modified
            engine.reload(storage.loadConfig())
        }
    }

    private func currentScreens() -> [Screen] {
        ([backlight] as [Screen?]).compactMap { $0 } + monitors.values.sorted { $0.name < $1.name }
    }

    private func stop() {
        engine?.stop()
        gnomeAuto.restore()
        server = nil
        Self.log("stopped")
        exit(0)
    }

    /// `brilho status` while the service isn't running: what it would find.
    public func survey() -> String {
        var lines = ["Brilho \(brilhoVersion) isn't running (systemctl --user start brilho)"]
        lines.append("Light sensor: " + (IIOLight.find(paths).map { "\($0.name), " + ($0.lux().map { "\(Int($0.rounded())) lux" } ?? "no reading") }
            ?? "none: Brilho follows the time of day"))
        if let backlight = Backlight.find(paths, runner: runner) {
            lines.append("Panel: \(URL(fileURLWithPath: backlight.device).lastPathComponent), "
                + (backlight.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "unreadable")
                + (backlight.writable ? "" : ", set through logind"))
        } else {
            lines.append("Panel: none")
        }
        var problems: [String] = []
        let found = DDCMonitor.find(paths) { problems.append($0) }
        for monitor in found { lines.append("Monitor: \(monitor.name) [\(monitor.key)]") }
        lines += problems
        if found.isEmpty, problems.isEmpty { lines.append("Monitors: none found over DDC") }
        return lines.joined(separator: "\n")
    }
}

public let brilhoVersion = "1.0"

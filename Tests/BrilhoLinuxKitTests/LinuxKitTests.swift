// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import BrilhoEngine
@testable import BrilhoLinuxKit
import Foundation
import Testing

/// A made-up machine's /sys and /dev, in a temporary directory.
final class FakeMachine {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brilho-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("sys"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("dev"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var paths: Paths { Paths(sys: root.path + "/sys", dev: root.path + "/dev") }

    func file(_ path: String, _ contents: String) { data(path, Data((contents + "\n").utf8)) }

    func data(_ path: String, _ contents: Data) {
        let url = root.appendingPathComponent("sys/" + path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: url)
    }

    func link(_ path: String, to target: String) {
        let url = root.appendingPathComponent("sys/" + path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    func device(_ name: String) { _ = FileManager.default.createFile(atPath: root.path + "/dev/" + name, contents: Data()) }

    func read(_ path: String) -> String? {
        (try? String(contentsOf: root.appendingPathComponent("sys/" + path), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The programs Brilho would run, recorded, with the replies given.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var replies: [String: String] = [:] // by the program and its arguments, joined by spaces

    var calls: [[String]] { lock.withLock { recorded } }

    var runner: Runner {
        Runner { program, arguments in
            self.lock.withLock {
                self.recorded.append([program] + arguments)
                return self.replies[([program] + arguments).joined(separator: " ")]
            }
        }
    }
}

/// An EDID's first block, as a monitor would give it.
func edid(vendor: UInt16, model: UInt16, serial: UInt32, name: String?) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    bytes[8] = UInt8(vendor >> 8)
    bytes[9] = UInt8(vendor & 0xFF)
    bytes[10] = UInt8(model & 0xFF)
    bytes[11] = UInt8(model >> 8)
    for i in 0..<4 { bytes[12 + i] = UInt8((serial >> (8 * UInt32(i))) & 0xFF) }
    if let name {
        let text = Array(name.utf8.prefix(13)) + (name.count < 13 ? [0x0A] : [])
        bytes.replaceSubrange(54..<59, with: [0, 0, 0, 0xFC, 0])
        for (i, byte) in (text + [UInt8](repeating: 0x20, count: 13)).prefix(13).enumerated() { bytes[59 + i] = byte }
    }
    bytes[127] = UInt8((256 - bytes[0..<127].reduce(0) { ($0 + Int($1)) % 256 }) % 256)
    return bytes
}

@Suite struct EDIDs {
    @Test func namesAndKeysAMonitorAsTheMacDoes() {
        let asus = EDID(edid(vendor: 0x06B3, model: 0x27E1, serial: 0x2000_0000, name: "PA279CRV"))
        #expect(asus?.key == "1715-10209-536870912") // the key Brilho on the Mac keeps it under
        #expect(asus?.manufacturer == "AUS")
        #expect(asus?.name == "PA279CRV")
        let aoc = EDID(edid(vendor: 0x05E3, model: 0x2590, serial: 14488, name: "2590G4"))
        #expect(aoc?.key == "1507-9616-14488" && aoc?.manufacturer == "AOC" && aoc?.name == "2590G4")
        #expect(EDID(edid(vendor: 0x10AC, model: 1, serial: 0, name: nil))?.name == nil)
        #expect(EDID([UInt8](repeating: 0, count: 128)) == nil)
        #expect(EDID(Array(edid(vendor: 1, model: 1, serial: 1, name: nil).prefix(100))) == nil)
    }
}

@Suite struct Sensors {
    @Test func processedLux() {
        let machine = FakeMachine()
        machine.file("bus/iio/devices/iio:device0/name", "als")
        machine.file("bus/iio/devices/iio:device0/in_illuminance_input", "123.5")
        let light = IIOLight.find(machine.paths)
        #expect(light?.name == "als" && light?.lux() == 123.5)
    }

    @Test func rawWithScaleAndOffset() {
        let machine = FakeMachine()
        machine.file("bus/iio/devices/iio:device0/name", "accel") // not a light sensor
        machine.file("bus/iio/devices/iio:device0/in_accel_x_raw", "12")
        machine.file("bus/iio/devices/iio:device1/in_illuminance_raw", "100")
        machine.file("bus/iio/devices/iio:device1/in_illuminance_scale", "0.5")
        machine.file("bus/iio/devices/iio:device1/in_illuminance_offset", "10")
        #expect(IIOLight.find(machine.paths)?.lux() == 55)
        machine.file("bus/iio/devices/iio:device1/in_illuminance_raw", "-30") // nonsense: no reading
        #expect(IIOLight.find(machine.paths)?.lux() == nil)
    }

    @Test func numberedChannelWithoutScale() {
        let machine = FakeMachine()
        machine.file("bus/iio/devices/iio:device3/in_illuminance0_raw", "200")
        #expect(IIOLight.find(machine.paths)?.lux() == 200)
    }

    @Test func noSensor() { #expect(IIOLight.find(FakeMachine().paths) == nil) }
}

@Suite struct Panels {
    func laptop() -> FakeMachine {
        let machine = FakeMachine()
        machine.file("class/backlight/intel_backlight/type", "raw")
        machine.file("class/backlight/intel_backlight/max_brightness", "1000")
        machine.file("class/backlight/intel_backlight/brightness", "400")
        machine.file("class/backlight/acpi_video0/type", "firmware")
        machine.file("class/backlight/acpi_video0/max_brightness", "100")
        machine.file("class/backlight/acpi_video0/brightness", "50")
        return machine
    }

    @Test func picksTheFirmwaresAndSetsIt() {
        let machine = laptop()
        let panel = Backlight.find(machine.paths)
        #expect(panel?.device.hasSuffix("acpi_video0") == true)
        #expect(panel?.brightness == 0.5)
        panel?.setBrightness(0.234)
        #expect(machine.read("class/backlight/acpi_video0/brightness") == "23")
        panel?.setBrightness(0) // never off
        #expect(machine.read("class/backlight/acpi_video0/brightness") == "1")
        #expect(panel?.resolution == 0.01)
    }

    @Test func throughLogindWhereItCantWrite() {
        let machine = laptop()
        let recorder = Recorder()
        let panel = Backlight(machine.paths.sys + "/class/backlight/intel_backlight", runner: recorder.runner, writable: false)
        panel.setBrightness(0.5)
        #expect(recorder.calls.last == ["busctl", "--timeout=2", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
                                        "org.freedesktop.login1.Session", "SetBrightness", "ssu", "backlight", "intel_backlight", "500"])
        #expect(panel.stepInterval > 0.1) // fewer steps than a file takes
    }

    @Test func none() { #expect(Backlight.find(FakeMachine().paths) == nil) }
}

@Suite struct PowerSources {
    @Test(arguments: [
        ([("AC", "Mains", "1", nil), ("BAT0", "Battery", nil, nil)], false),
        ([("AC", "Mains", "0", nil), ("BAT0", "Battery", nil, nil)], true),
        ([("ucsi-source-psy-1", "USB", "1", nil), ("BAT0", "Battery", nil, nil)], false),
        ([("hidpp_battery_0", "Battery", nil, "Device")], false), // a mouse's
        ([], false),
    ] as [([(String, String, String?, String?)], Bool)])
    func onBatteryOnlyWithNothingPluggedIn(supplies: [(String, String, String?, String?)], expected: Bool) {
        let machine = FakeMachine()
        for (name, type, online, scope) in supplies {
            machine.file("class/power_supply/\(name)/type", type)
            if let online { machine.file("class/power_supply/\(name)/online", online) }
            if let scope { machine.file("class/power_supply/\(name)/scope", scope) }
        }
        #expect(Power.onBattery(machine.paths) == expected)
    }
}

/// A monitor answering DDC/CI as a real one would, with its replies' framing.
final class FakeBus: DDCBus, @unchecked Sendable {
    var values: [UInt8: (value: Int, max: Int)] = [0x10: (40, 100), 0x12: (58, 100)]
    var sets: [(UInt8, Int)] = []
    var gate: DispatchSemaphore? // holds a get until signalled

    func exchange(_ message: [UInt8], reply: Int) -> [UInt8]? {
        #expect(message.last == message.dropLast().reduce(0x6E ^ 0x51, ^)) // checksummed
        switch message[0] {
        case 0x82: // get
            gate?.wait()
            let control = message[2]
            guard let state = values[control] else { return [0x6E, 0x88, 0x02, 0x01, control, 0, 0, 0, 0, 0, 0] } // unsupported
            return [0x6E, 0x88, 0x02, 0x00, control, 0x00, UInt8(state.max >> 8), UInt8(state.max & 0xFF),
                    UInt8(state.value >> 8), UInt8(state.value & 0xFF), 0]
        case 0x84: // set
            let control = message[2], value = Int(message[3]) << 8 | Int(message[4])
            sets.append((control, value))
            values[control]?.value = value
            return []
        default:
            return nil
        }
    }
}

/// What the main queue does for Brilho: here, run when the test says.
final class Pump: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [() -> Void] = []

    func respond(_ work: @escaping () -> Void) { lock.withLock { waiting.append(work) } }

    func run() {
        while let work = lock.withLock({ waiting.isEmpty ? nil : waiting.removeFirst() }) { work() }
    }
}

@Suite struct Monitors {
    @Test func readsSetsAndCoalesces() {
        let bus = FakeBus(), pump = Pump()
        let monitor = DDCMonitor(key: "1507-9616-14488", name: "2590G4", bus: bus, respond: pump.respond)
        monitor.drain(pump: pump.run)
        #expect(monitor.brightness == 0.4)
        #expect(monitor.contrast?.value == 58)
        for setting in [0.5, 0.6, 0.7] { monitor.setBrightness(setting) }
        monitor.drain(pump: pump.run)
        #expect(bus.values[0x10]?.value == 70)
        #expect(bus.sets.count <= 2) // the first, and the latest
        monitor.setContrast(60)
        monitor.drain(pump: pump.run)
        #expect(bus.values[0x12]?.value == 60)
    }

    @Test func aReplyOvertakenByASetIsDropped() {
        let bus = FakeBus(), pump = Pump()
        let monitor = DDCMonitor(key: "k", name: "m", bus: bus, respond: pump.respond)
        monitor.drain(pump: pump.run)
        bus.gate = DispatchSemaphore(value: 0)
        monitor.refresh() // held on the bus
        monitor.setBrightness(0.9)
        bus.values[0x10]?.value = 20 // what the held read will say
        bus.gate?.signal()
        bus.gate?.signal()
        bus.gate = nil
        monitor.drain(pump: pump.run)
        #expect(monitor.brightness == 0.9)
        #expect(bus.values[0x10]?.value == 90)
    }

    @Test func foundByTheirConnectors() {
        let machine = FakeMachine()
        let asus = Data(edid(vendor: 0x06B3, model: 0x27E1, serial: 0x2000_0000, name: "PA279CRV"))
        machine.file("class/drm/card0-eDP-1/status", "connected") // the laptop's own panel
        machine.data("class/drm/card0-eDP-1/edid", Data(edid(vendor: 0x09E5, model: 1, serial: 0, name: nil)))
        machine.file("class/drm/card0-DP-1/status", "connected")
        machine.data("class/drm/card0-DP-1/edid", asus)
        machine.link("class/drm/card0-DP-1/ddc", to: "../../../0000:00:02.0/i2c-5")
        machine.device("i2c-5")
        machine.file("class/drm/card0-HDMI-A-1/status", "disconnected")
        machine.file("class/drm/card1-DP-2/status", "connected")
        machine.data("class/drm/card1-DP-2/edid", Data(edid(vendor: 0x05E3, model: 0x2590, serial: 14488, name: "2590G4")))
        machine.file("class/drm/card1-DP-2/i2c-7/name", "DPDDC-B") // an AUX channel's bus, but no /dev/i2c-7
        machine.file("class/drm/version", "drm 1.1.0")
        var problems: [String] = []
        let found = DDCMonitor.find(machine.paths) { problems.append($0) }
        #expect(found.map(\.key) == ["1715-10209-536870912"])
        #expect(found.first?.name == "PA279CRV")
        #expect((found.first?.bus as? I2CBus)?.path == machine.paths.dev + "/i2c-5")
        #expect(problems.count == 1 && problems[0].contains("modprobe i2c-dev"))
        // Found again, the same one is kept
        let again = DDCMonitor.find(machine.paths, existing: Dictionary(uniqueKeysWithValues: found.map { ($0.key, $0) }))
        #expect(again.first === found.first)
    }
}

@Suite struct Desktops {
    @Test func gnomesNightLightIsDrivenAndPutBack() {
        let recorder = Recorder()
        let schema = "org.gnome.settings-daemon.plugins.color"
        recorder.replies = [
            "gsettings get \(schema) night-light-temperature": "uint32 2700", "gsettings get \(schema) night-light-enabled": "false",
            "gsettings get \(schema) night-light-schedule-automatic": "true", "gsettings get \(schema) night-light-schedule-from": "20.0",
            "gsettings get \(schema) night-light-schedule-to": "6.0",
        ]
        #expect(GnomeNightLight(runner: recorder.runner, desktop: "KDE") == nil)
        let night = GnomeNightLight(runner: recorder.runner, desktop: "ubuntu:GNOME")!
        func sets() -> [[String]] { recorder.calls.filter { $0[1] == "set" }.map { Array($0[3...]) } }
        #expect(sets() == [["night-light-schedule-automatic", "false"], ["night-light-schedule-from", "0.0"], ["night-light-schedule-to", "0.0"]])
        night.setWhite(6500)
        #expect(sets().last == ["night-light-enabled", "false"])
        night.setWhite(3500)
        #expect(Array(sets().suffix(2)) == [["night-light-temperature", "3500"], ["night-light-enabled", "true"]])
        let count = sets().count
        night.setWhite(3510) // too little to bother GNOME with
        #expect(sets().count == count)
        night.setWhite(1500)
        #expect(sets().last == ["night-light-temperature", "1700"]) // GNOME's warmest
        night.reset()
        #expect(sets().contains(["night-light-temperature", "2700"]) && sets().contains(["night-light-schedule-from", "20.0"]))
    }

    @Test func gnomesOwnAutomaticBrightnessIsTurnedOffAndBack() {
        let recorder = Recorder()
        recorder.replies = ["gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled": "true"]
        let auto = GnomeAutoBrightness(runner: recorder.runner)
        var logged: [String] = []
        auto.turnOff { logged.append($0) }
        #expect(recorder.calls.last == ["gsettings", "set", "org.gnome.settings-daemon.plugins.power", "ambient-enabled", "false"])
        #expect(logged.count == 1)
        auto.restore()
        #expect(recorder.calls.last == ["gsettings", "set", "org.gnome.settings-daemon.plugins.power", "ambient-enabled", "true"])
    }

    @Test func theCircumstances() {
        let machine = FakeMachine()
        machine.file("class/power_supply/AC/type", "Mains")
        machine.file("class/power_supply/AC/online", "0")
        machine.file("class/power_supply/BAT0/type", "Battery")
        let recorder = Recorder()
        recorder.replies = [
            "busctl --user --timeout=2 call org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.Settings ReadOne ss org.freedesktop.appearance color-scheme": "v u 1",
            "busctl --user --timeout=2 call org.gnome.Mutter.IdleMonitor /org/gnome/Mutter/IdleMonitor/Core org.gnome.Mutter.IdleMonitor GetIdletime": "t 12345",
        ]
        let surroundings = LinuxSurroundings(paths: machine.paths, runner: recorder.runner, x11: nil)
        let context = surroundings.context(night: 0.25)
        #expect(context == Context(night: 0.25, app: nil, dark: true, battery: true))
        #expect(surroundings.idleTime() == 12.345)
    }
}

@Suite struct Keeping {
    @Test func settingsAndStateRoundTrip() throws {
        let machine = FakeMachine()
        let storage = Storage(config: machine.root.appendingPathComponent("config/brilho/config.json"),
                              state: machine.root.appendingPathComponent("state/brilho/state.json"))
        var config = Config()
        config.wake = 510
        config.latitude = 38.72
        storage.save(config)
        #expect(storage.loadConfig() == config)
        var state = State()
        state.displays["builtin", default: Stored()].brightness = [Adjustment(x: 2, value: 2.1, date: Date(timeIntervalSince1970: 1e9))]
        storage.save(state)
        #expect(storage.loadState().displays["builtin"]?.brightness.first?.value == 2.1)
        #expect(storage.configModified != nil)
    }

    @Test func anUnreadableFileIsKeptAside() throws {
        let machine = FakeMachine()
        let config = machine.root.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: config)
        let storage = Storage(config: config, state: machine.root.appendingPathComponent("state.json"))
        #expect(storage.loadConfig() == Config())
        #expect(FileManager.default.fileExists(atPath: config.path + ".unreadable"))
    }
}

@Suite struct Commands {
    @Test func aCommandReachesTheServiceAndItsReplyComesBack() {
        let path = "/tmp/brilho-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = Socket.Server(path: path, queue: DispatchQueue(label: "test")) { words in words.joined(separator: "+") }
        #expect(server != nil)
        #expect(Socket.send(["brighter", "Built-in display"], to: path) == "brighter+Built-in display")
        #expect(Socket.send(["status"], to: "/tmp/brilho-nothing-here.sock") == nil)
        _ = server
    }
}

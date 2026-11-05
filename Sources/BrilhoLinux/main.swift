// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later
//
// brilho, on Linux: keeps the laptop's panel and the monitors (over DDC/CI) at
// the brightness the room's light calls for, learning from every change the
// user makes, and warms the screens at night. `brilho run` is the service,
// which systemd starts with the desktop; the other commands talk to it.

import BrilhoCore
import BrilhoEngine
import BrilhoLinuxKit
import Foundation

let usage = """
Brilho \(brilhoVersion): automatic brightness that learns.

  brilho run                   the service (systemctl --user enable --now brilho)
  brilho status                what it sees, and what it has learnt
  brilho brighter [SCREEN]     a sixteenth brighter, learnt (every screen, or the one named)
  brilho dimmer [SCREEN]       a sixteenth dimmer, learnt
  brilho warmer | cooler       Night Warmth's strength, learnt for this time of night
  brilho pause | resume        stop following the light, and start again
  brilho night-warmth on|off
  brilho location LAT LON      where you are, for sunset times
  brilho wake HH:MM            when you wake, for when the night starts
  brilho nits SCREEN MIN MAX   a screen's nits at its lowest and highest, from its specifications
  brilho forget                forget every adjustment

Change the brightness as you always do (the keys, your desktop's slider, a monitor's buttons): Brilho learns from it.
"""

/// Settings commands, and forgetting, work with the service stopped too: on the files it reads.
final class Nowhere: Surroundings {
    func context(night: Double) -> Context { Context(night: night) }
    func idleTime() -> TimeInterval? { nil }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run":
    Service().run()
case nil, "help", "--help", "-h":
    print(usage)
case "version", "--version":
    print("Brilho \(brilhoVersion)")
default:
    if let reply = Socket.send(arguments) {
        print(reply)
    } else if arguments.first == "status" {
        print(Service().survey())
    } else if ["pause", "resume", "night-warmth", "location", "wake", "forget"].contains(arguments[0]) {
        let storage = Storage.standard
        let engine = Engine(sensor: nil, screens: [], white: nil, surroundings: Nowhere(), config: storage.loadConfig(),
                            state: storage.loadState(), save: { storage.save($0) }, saveConfig: { storage.save($0) }, log: { _ in })
        print(engine.command(arguments, at: Date()))
    } else {
        print("Brilho isn't running: systemctl --user start brilho")
        exit(1)
    }
}

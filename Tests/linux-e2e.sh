#!/bin/sh
# SPDX-FileCopyrightText: 2026 Machado65
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Brilho's service, run for real on a made-up laptop: a light sensor and a
# panel in a fake /sys, its commands sent over its socket.
#
#   Tests/linux-e2e.sh path/to/brilho
set -eu
bin=$(cd "$(dirname "${1:?usage: linux-e2e.sh path/to/brilho}")" && pwd)/$(basename "$1")
root=$(mktemp -d)
pid=
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$root"
}
trap cleanup EXIT
sys=$root/sys
sensor=$sys/bus/iio/devices/iio:device0
panel=$sys/class/backlight/intel_backlight
mkdir -p "$sensor" "$panel" "$root/dev" "$root/run" "$root/config" "$root/state"
echo als > "$sensor/name"
echo 300 > "$sensor/in_illuminance_input"
echo raw > "$panel/type"
echo 1000 > "$panel/max_brightness"
echo 100 > "$panel/brightness"
export BRILHO_SYS="$sys" BRILHO_DEV="$root/dev" XDG_RUNTIME_DIR="$root/run" XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state"
unset DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP

fail() {
    echo "FAIL: $*"
    cat "$root/log"
    exit 1
}
brightness() { cat "$panel/brightness"; }
# wait_for CONDITION SECONDS
wait_for() {
    tenths=0
    until eval "$1"; do
        tenths=$((tenths + 1))
        [ "$tenths" -le $(($2 * 10)) ] || return 1
        sleep 0.1
    done
}

"$bin" status | grep -q "isn't running" || fail "status without the service"

"$bin" run 2> "$root/log" &
pid=$!

# It follows the light: about 190 nits at 300 lux, 55% of a panel guessed at 3 to 350 nits
wait_for '[ "$(brightness)" -ge 520 ] && [ "$(brightness)" -le 570 ]' 20 || fail "didn't follow the light: $(brightness)"
echo "follows the light: $(brightness)/1000"

# Less light, a dimmer panel, settling as the light does
echo 20 > "$sensor/in_illuminance_input"
wait_for '[ "$(brightness)" -lt 250 ]' 30 || fail "didn't dim with the light: $(brightness)"
last=
until [ "$(brightness)" = "$last" ]; do
    last=$(brightness)
    sleep 3
done
echo "dims with the light: $(brightness)/1000"

# Its commands reach it
"$bin" status | grep -q "Built-in display" || fail "status: $("$bin" status)"

# What the user sets (the desktop's keys) is learnt, and not fought
echo 700 > "$panel/brightness"
wait_for 'grep -q "\"setting\"" "$root/state/brilho/state.json" 2>/dev/null' 10 || fail "the user's setting wasn't learnt"
sleep 3
[ "$(brightness)" -ge 690 ] || fail "fought the user: $(brightness)"
echo "learns the user's setting and keeps it: $(brightness)/1000"

"$bin" dimmer > /dev/null
[ "$(brightness)" -le 630 ] || fail "dimmer: $(brightness)"
"$bin" pause | grep -q Paused || fail "pause"
grep -Eq '"enabled" ?: ?false' "$root/config/brilho/config.json" || fail "pause wasn't kept"
echo "commands work: dimmer to $(brightness)/1000, paused"

kill -TERM "$pid"
wait "$pid" || fail "didn't stop cleanly"
pid=
grep -q stopped "$root/log" || fail "didn't say it stopped"
echo "linux e2e: ok"

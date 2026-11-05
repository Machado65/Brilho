#!/bin/sh
# SPDX-FileCopyrightText: 2026 Machado65
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Brilho.app with SwiftPM (the Command Line Tools are enough, no Xcode)
# into ~/Applications (or $BRILHO_APP), signs it and starts it again.
#
#   ./build.sh                   build, install and restart
#   ./build.sh --local-identity  the same, making a local signing identity first
#   ./build.sh --no-restart      build and install only
#   ./build.sh test              run the tests
#
# Signing, in order: $BRILHO_IDENTITY when set (a Developer ID certificate,
# say); else the local identity made by --local-identity, under which macOS
# keeps the Accessibility permission across rebuilds; else ad hoc, which works
# but asks for Accessibility again after every build.
set -eu
cd "$(dirname "$0")"

if [ "${1:-}" = test ]; then
    # The Command Line Tools' swift test doesn't always find the testing macros by itself
    plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
    if [ -d "$plugins" ]; then
        exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins"
    fi
    exec swift test
fi

app="${BRILHO_APP:-$HOME/Applications/Brilho.app}"
keychain="$HOME/Library/Application Support/Brilho/signing.keychain-db"
restart=true
for argument in "$@"; do
    case "$argument" in
        --no-restart) restart=false ;;
        --local-identity) [ -f "$keychain" ] || make_identity=true ;;
        *) echo "unknown option $argument" >&2; exit 2 ;;
    esac
done

if [ "${make_identity:-false}" = true ]; then
    # A self-signed certificate in a keychain of its own, kept out of the search
    # list; its password only guards this certificate
    mkdir -p "$(dirname "$keychain")"
    tmp=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Brilho Local" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/identity.p12" -passout pass:brilho
    searchlist=$(security list-keychains -d user | tr -d '"')
    security create-keychain -p brilho "$keychain"
    # shellcheck disable=SC2086 # one path per word, as listed
    security list-keychains -d user -s $searchlist
    security import "$tmp/identity.p12" -k "$keychain" -P brilho -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k brilho "$keychain" >/dev/null
    rm -rf "$tmp"
fi

swift build -c release --product Brilho
bin=$(swift build -c release --show-bin-path)
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/"
# Replaced, not written over: a running copy keeps its file
rm -f "$app/Contents/MacOS/Brilho"
cp "$bin/Brilho" "$app/Contents/MacOS/Brilho"

if [ -n "${BRILHO_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$BRILHO_IDENTITY" "$app"
elif [ -f "$keychain" ]; then
    security unlock-keychain -p brilho "$keychain"
    codesign --force --keychain "$keychain" --sign "Brilho Local" "$app"
else
    codesign --force --sign - "$app"
fi
# So that brilho:// URLs reach it
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "built $app"

[ "$restart" = true ] || exit 0
# Start it again: through the launchd job that runs it, if there is one, else
# directly. The old one has to be gone first, or the new one sees it running
# and quits.
pkill -x Brilho || true
while pgrep -x Brilho >/dev/null; do sleep 0.1; done
job=$(launchctl list | awk 'tolower($3) ~ /brilho/ { print $3; exit }')
if [ -n "$job" ]; then
    launchctl kickstart "gui/$(id -u)/$job"
else
    open "$app"
fi

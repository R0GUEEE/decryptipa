#!/bin/sh
# Compiles the device-free logic (Mach-O cryptid parsing, @evt parsing, version
# comparison) into a small command-line harness and runs its self-checks.
# The two source files are copied rather than linked so the app target stays the
# single source of truth.
set -eu

cd "$(dirname "$0")"

APP_SOURCES="../../Sources/DecryptIPA"
DEST="Sources/LogicCheck"

cp "$APP_SOURCES/MachO.swift" "$DEST/MachO.swift"
cp "$APP_SOURCES/Events.swift" "$DEST/Events.swift"

swift run -c release LogicCheck

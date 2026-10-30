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
cp "$APP_SOURCES/Models.swift" "$DEST/Models.swift"
cp "$APP_SOURCES/AppStore/AppStoreLookup.swift" "$DEST/AppStoreLookup.swift"
cp "$APP_SOURCES/AppStore/AppStoreClient.swift" "$DEST/AppStoreClient.swift"
cp "$APP_SOURCES/AppStore/Anisette.swift" "$DEST/Anisette.swift"
cp "$APP_SOURCES/AppStore/TwoFactor.swift" "$DEST/TwoFactor.swift"

# The request funnel must delegate to the HTTP transport. A self-call here
# compiles but recursively allocates until iOS jetsams the app on first login.
rg -U -q '(?s)func perform\(_ request: URLRequest\).*?let \(data, response\) = try await http\.send\(request\)' \
  "$APP_SOURCES/AppStore/AppStoreClient.swift" || {
  echo "AppStoreClient.perform must dispatch to http.send (not itself)" >&2
  exit 1
}

swift run -c release LogicCheck

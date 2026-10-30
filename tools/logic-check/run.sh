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
python3 - "$APP_SOURCES/AppStore/AppStoreClient.swift" <<'PYGUARD'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("func perform(_ request: URLRequest)")
end = source.index("// MARK: Bag", start)
body = source[start:end]
if "try await http.send(request)" not in body or "try await perform(request)" in body:
    raise SystemExit("AppStoreClient.perform must dispatch to http.send (not itself)")
PYGUARD

swift run -c release LogicCheck

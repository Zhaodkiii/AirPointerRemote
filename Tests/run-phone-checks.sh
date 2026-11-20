#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/watchpointer-checks.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
swiftc Shared/PhoneProtocol.swift \
    Mac/Input/PhoneMouse.swift \
    Mac/Input/Displays.swift \
    iPhone/Remote/AirMotionFilter.swift \
    Tests/PhoneProtocolChecks.swift -o "$checks_dir/checks"
"$checks_dir/checks"

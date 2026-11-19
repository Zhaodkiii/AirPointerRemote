#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/watchpointer-checks.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
swiftc Shared/PhoneProtocol.swift \
    Mac/PhoneMouse.swift \
    Mac/Displays.swift \
    iPhone/AirMotionFilter.swift \
    Tests/PhoneProtocolChecks.swift -o "$checks_dir/checks"
"$checks_dir/checks"

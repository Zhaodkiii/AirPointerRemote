#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/airpointer-linked.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
swiftc Shared/PhoneProtocol.swift Shared/LinkedTransport.swift Mac/LinkedEncoder.swift Mac/LinkedVideoQuality.swift \
    iPhone/LinkedDecoder.swift Tests/LinkedScreenChecks.swift -o "$checks_dir/checks"
"$checks_dir/checks"

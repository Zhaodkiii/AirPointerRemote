#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/DesktopTest.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cp iPhone/Resources/SystemDesktop.html "$app/Resources/"
xcrun swiftc -swift-version 5 Tests/SystemDesktop/main.swift iPhone/SystemDesktop/{DesktopSession,DesktopComputer,MirrorVideo}.swift -o "$app/MacOS/Test"
python3 Tests/SystemDesktop/check.py "$app/MacOS/Test"

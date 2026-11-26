# Build, Use, and Release

Open `GlideCueRemote.xcodeproj` in Xcode and select a scheme.

| Scheme | Minimum OS | Bundle ID |
| --- | --- | --- |
| GlideCue Remote iPhone | iOS 18 | `cn.zhaodk.glidecue` |
| GlideCue Remote Watch | watchOS 11 | `cn.zhaodk.glidecue.watchkitapp` |
| GlideCue Remote Mac | macOS 14 | `cn.zhaodk.glidecue` |
| GlideCue Remote Mac Direct | macOS 14 | `cn.zhaodk.glidecue.direct` |

Open the Mac receiver, allow Bluetooth access, and enable the app under **System Settings → Privacy & Security → Accessibility**. Select the Mac on your iPhone or Apple Watch to pair. A different bundle ID requires fresh permissions and pairing. Use the Mac menu bar to pause control, revoke iPhone pairings, or quit. Press Control + Option + Command + Period for an emergency stop.

The Mac Debug configuration uses the development pointer-control setup. Release enables App Sandbox and Bluetooth access for Mac App Store distribution. Verify Bluetooth discovery, pairing, pointer movement, clicking, dragging, and scrolling on a physical Mac with a signed Release build. To run that configuration in Xcode, set **Run → Build Configuration** to **Release** in the Mac scheme.

## Screen Sharing from iPhone

Open **Built-in Screen Sharing** on iPhone to discover your Mac on the local network or connect by VNC address. See the [Screen Sharing Guide](system-desktop.md) for setup, sign-in methods, and device testing.

## Repository Layout

| Directory | Contents |
| --- | --- |
| `iPhone/` | App entry point, pairing, pointer control, screen sharing, and setup guide |
| `Mac/` | Receiver, device connections, pointer input, menu bar, screen capture, and video encoding |
| `Watch/` | Apple Watch controls and connection logic |
| `Shared/` | Pairing protocol and screen-sharing transport |
| Platform `Resources/` directories | Icons, privacy manifests, and localization. iPhone also includes setup videos and the generated Mac installer. |
| `Config/` | Info.plist files used by Xcode |
| `Tests/`, `scripts/` | Protocol and streaming checks, and Mac installer packaging |
| `docs/`, `Game/` | Documentation, demos, and a standalone browser game |

## App Store Distribution

1. Register `cn.zhaodk.glidecue` with Apple Developer and create an iOS app record in App Store Connect with English (U.S.) as the primary language.
2. Archive with the **GlideCue Remote iPhone** scheme and a generic iOS device destination. This archive contains the iPhone app only.
3. Validate and upload the signed archive from Xcode Organizer. Verify the build in TestFlight, then provide screenshots, privacy and support information, export compliance details, and pairing instructions.

## Closed-Lid Desktop

Open **GlideCue Remote Direct** from Applications. **Closed-Lid Desktop** opens on first launch and is available from the Mac menu bar afterward. With the lid open, enable the feature, grant Screen Recording and Accessibility access, and click **Set Up** under **Closed-Lid Power**. Follow the prompts to allow the background service. The Direct edition uses its own bundle ID and requires a new pairing.

On your paired iPhone, tap **Share** or **Linked Screen → Start Sharing**. Wait for **Lid Desktop** and **Ready to close the Mac lid** before closing the lid. Opening the lid restores the built-in display brightness while sharing continues on the virtual desktop. To switch to the built-in display, tap **Choose a Display on the Mac**. Ending the session restores the original Mac sleep settings.

Quit the standard receiver and any standalone Lid Desktop utility before opening the Direct edition. Before uninstalling the Direct edition, end the session and click **Remove Power Helper**. Verify first-run permissions, lid closure, low battery, and crash recovery on a physical Mac. The virtual display and brightness controls use private macOS APIs, so retest them after macOS upgrades.

## Mac Installer

From the repository root, run the packaging script.

```bash
./scripts/build-mac-dmg.sh
```

The default command builds the standard Mac Release and refreshes the installer bundled with iPhone. Running `./scripts/dmg-layout.py` directly invokes the same workflow. The script builds for Apple silicon and Intel and signs with a Developer ID Application certificate from team `4AN6PV98G7`. It requires Xcode and Python 3 and installs dmgbuild into a local build directory on first run. By default, it uses the team account signed in to Xcode to notarize the app inside the DMG. The resulting image appears in `DerivedData/WebsiteRelease/` with an `-app-notarized` suffix.

To notarize the Direct edition DMG for website distribution, run the script with a configured notarytool Keychain profile.

```bash
AIRPOINTER_NOTARY_PROFILE=AirPointerNotary ./scripts/build-mac-dmg.sh --direct
```

`AirPointerNotary` is an example profile name. Run `xcrun notarytool store-credentials AirPointerNotary` to configure a profile. The script verifies the DMG’s notarization ticket and the app’s signature, then prints the installer path with its version and build number. Open the DMG, drag GlideCue Remote into Applications, and launch it to see the receiver in the menu bar.

Use `--standard` to explicitly build the standard edition and update `iPhone/Resources/GlideCue Remote for Mac.dmg`. After rebuilding the iPhone app, users can find the installer under **Choose Your Mac → Set Up Your Mac → Share Mac Installer**. Use `--direct` to build the separate `-Direct` DMG.

## Development Checks

Run `Tests/run-phone-checks.sh` to check pairing, motion conversion, and mouse event generation. Verify system-wide pointer control on a physical Mac.

See the [release checklist](release-readiness.md) for first-release checks, App Review considerations, and reviewer notes.

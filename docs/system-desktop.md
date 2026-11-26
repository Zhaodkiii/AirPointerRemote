# Mac Screen Sharing from iPhone

## Mirror Your Mac

1. On your Mac, open **System Settings → General → Sharing**. Turn on **Screen Sharing**, open its settings, and choose which users can connect. Note the displayed VNC address. To sign in with a Mac account, use that Mac’s username and password. To use a dedicated VNC password, enable the VNC password option and set one.
2. Connect your iPhone and Mac to the same trusted local network. On the GlideCue Remote home screen, open **Built-in Screen Sharing** and grant local network access when prompted.
3. Select **Mirror Mac Screen** and choose a nearby Mac or enter its address. The default port is 5900. For a different port, use an address such as `mac.local:5901` or `vnc://[IPv6]:5901`.
4. On the first connection, choose Mac account or VNC password authentication. After sign-in, the Mac appears in the saved list, and its credentials are stored in the iPhone Keychain. Selecting the same address signs in automatically. To update saved credentials, connect with the new password. Touch and hold a saved Mac to remove the address and credentials.
5. Use the floating toolbar for the keyboard, modifier keys, arrow keys, shortcuts, and settings. Choose fit, fill, actual size, or observe-only mode. Fill crops the display. Rotate to landscape to see more of a wide desktop, pinch to zoom, or drag with two fingers to pan. Reset to the full view from the toolbar. Use the tools panel to capture and share a screenshot. Disconnecting, locking iPhone, or leaving the app ends the session.

## iPhone Desktop

Install and open the current version of GlideCue Remote Direct on your Mac, then grant Bluetooth, Screen Recording, and Accessibility access. Bring the window you want to use to the front. On your iPhone, open **Built-in Screen Sharing**, choose **iPhone Desktop**, then select a nearby Mac to pair or tap **Start iPhone Desktop**.

The iPhone sends the size of its viewing area. The Mac creates a separate virtual display, moves the frontmost window onto it, and resizes the window to fit. When you rotate the iPhone, the Mac resizes the same display and restores touch control once the new frame arrives. On disconnect, the receiver attempts to restore the window’s original size and position and releases the display. Keep your Mac awake for this mode. Closed-lid sharing uses a separate setup.

### Touch and Toolbar

Tap to position the pointer and click. Swipe with one finger to scroll the Mac window or list under your finger. Enable the hand tool to drag Mac items. Pinch to zoom and use two fingers to pan while zoomed in.

The floating toolbar starts midway down the right side. Tap the ellipsis to expand it and the six-dot handle to collapse it. Drag either control to change its side and vertical position. The iPhone saves that position. Open the zoom menu to choose one of three toolbar sizes. The toolbar collapses and repositions when the keyboard appears.

## Standard VNC Client

- `DesktopDiscovery` uses Network.framework to browse the Bonjour service `_rfb._tcp`. The app stores discovered service names and domains and resolves them again on reconnect. Manually entered connections store a host and port. Search filters locally.
- `DesktopSession` connects directly to the macOS service with `NWConnection`. A bundled noVNC 1.7.0 client in `WKWebView` handles RFB decoding, rendering, and input. The in-process bridge passes binary data in batches of up to 64 KiB and waits for WebKit before reading again. The standard VNC path runs entirely on the local network.
- Mac account sign-in uses ARD authentication. VNC password sign-in uses VNC challenge-response. The app saves credentials in the local Keychain only after successful authentication, with separate records for each Bonjour service or manual address. Enter credentials on the first connection or after changing the address. Use standard VNC on a trusted network.
- Opening the standard remote desktop pauses Bluetooth pointer input. Each connection uses a fresh, nonpersistent WebView. Connection and authentication time out after 20 seconds. If sign-in fails, the form stays open so you can correct it and retry.
- Builds use the bundled client resources. After changing dependencies or the browser bridge, run `npm ci` and `node build.mjs` from `scripts/vnc-client` to regenerate the HTML and license files. Authentication filtering relies on methods from the pinned noVNC version. Rerun the protocol checks after upgrading.

## Testing and Troubleshooting

Run `Tests/SystemDesktop/run.sh` on macOS with Xcode and Python 3 with `cryptography` installed. The test uses a temporary local service and a WebKit session to verify VNC challenge-response, ARD credential encryption, initialization, and keyboard messages.

On physical devices, verify both sign-in methods, desktop rendering, clicking and dragging, rotation, Chinese text input, incorrect passwords, denied local network access, Wi-Fi interruption, backgrounding, and saving or removing addresses.

If discovery returns no results, connect directly to the address shown on your Mac to distinguish Bonjour discovery from TCP connectivity. If the direct connection also fails, check local network access, Mac sleep state, and router client isolation. If macOS rejects sign-in, check the allowed accounts or the dedicated VNC password.

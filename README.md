# iPad Screen for Mac

A native macOS host that turns a USB-connected, jailbroken iPad into a second
display. Extend the Mac desktop or mirror an existing screen using the installed
[iPad Screen companion](https://github.com/cevatkerim/ipad-screen).

The host uses SwiftUI, ScreenCaptureKit, VideoToolbox H.264, and macOS's built-in
USB device service. It does not require Homebrew, Python, ffmpeg, Wi-Fi, or a
personal hotspot. The iPad companion and its protocol are unchanged.

## Build and open

Requires macOS 14 or later and Xcode with Swift 5.9 or newer.

```sh
./scripts/build-app
open 'build/iPad Screen.app'
```

The build produces an app for the current Mac architecture, with a local ad-hoc
signature. To sign with an existing signing identity, set `CODESIGN_IDENTITY`
when building. Distribution signing and notarization are not configured.

## Connect your iPad

1. Connect the iPad by USB, trust the Mac if prompted, and unlock it. The existing
   iPad Screen companion and jailbreak SSH server must already be installed.
2. Select the device and choose **Pair iPad**. Enter the `mobile` SSH password,
   or expand **Use an existing SSH key** to use an already authorized key.
3. Choose **Extend Desktop** or **Mirror Display**. If macOS asks, allow screen
   recording in **System Settings → Privacy & Security → Screen & System Audio
   Recording**, then quit and reopen the app.
4. In Extend mode, move a window to the right of your Mac display. The iPad uses
   its native pixel resolution, with Retina scaling enabled by default. Change
   the layout through **More → Display Arrangement** if needed.

**Stop** removes the temporary display and disconnects USB streaming. The menu
bar controls remain available when the main window is closed. Quitting the app,
Mac sleep, a removed source display, or a failed USB connection ends the session
and releases the app's virtual display. After reconnecting or waking, start a new
session. Other displays and their configuration are preserved.

The host's keyboard and mouse control the desktop. iPad touch operates only the
companion's statistics controls; remote desktop touch input and audio are not
implemented. Different source aspect ratios are letterboxed when mirroring.

## Device profiles

| iPad | Native pixels | Retina desktop points |
| --- | --- | --- |
| Pro 9.7-inch | 2048 × 1536 | 1024 × 768 |
| Pro 10.5-inch | 2224 × 1668 | 1112 × 834 |
| 9th generation | 2160 × 1620 | 1080 × 810 |

Pairing detects these models through the selected device's SSH connection.
The Mac host has been exercised on Apple Silicon with the Pro 9.7-inch. Other
listed models, Intel Macs, and older supported macOS releases need hardware
validation. Start at 30 fps. The 60 fps option is a request, not a performance
guarantee. H.264 4:2:0 can soften colored text.

## Local state and security

Pairing adds a dedicated Mac SSH public key while preserving existing authorized
keys. The private key remains on the Mac. The password is used only for pairing
and its temporary private askpass file is removed when pairing finishes. The
host reads the companion's existing token over SSH; it does not reinstall the
companion or replace its token. SSH host keys use trust on first use over the
selected USB connection; changed host keys are rejected.

Development builds keep state in the repository's ignored `.runtime/`. When the
app is moved elsewhere, its default is
`~/Library/Application Support/iPad Screen/.runtime/`. Pair again there or copy
your existing pairing state and update its private-key path. `--state-dir PATH`
or `IPAD_SCREEN_STATE_DIR` overrides the location. Tokens, keys, and pairing files
are private to the current user. Never commit `.runtime/`, `.env`, identifiers,
screenshots, or logs. Aggregate session statistics are saved as
`.runtime/mac-session.json`; captured frames stay in memory.

One session may run per state directory, enforced with a file lock. Both the
native host and the Linux host's saved profile/token format are compatible; a
private-key path from another machine must be updated to a key on this Mac.

The receiver listens only on iPad loopback and is reached through usbmux, with
token authentication. Protocol v1 has no encryption independent of USB. Keep
that listener off the LAN. See [the protocol](docs/protocol.md).

## Command-line use

The same app executable provides bounded tests and shell control:

```sh
APP='build/iPad Screen.app/Contents/MacOS/IPadScreenMac'
"$APP" --diagnose
"$APP" --pair --key-file ~/.ssh/id_ed25519
"$APP" --run test --seconds 15
"$APP" --run mirror --seconds 30
"$APP" --run extend --seconds 30
"$APP" --check-virtual
"$APP" --help
```

Without `--seconds`, streaming continues until Ctrl+C or SIGTERM. For a specific
mirror source use `--display-id`; `--standard-scale` disables Retina extension.
The graphical app includes **More → Test Receiver**, which streams a moving
pattern without recording the desktop.

## Validation and design

```sh
swift test --scratch-path build/swift --cache-path build/swift-cache
```

Tests cover authentication and framing, malformed replies, partial USB writes,
disconnect cancellation, private pairing state, a real VideoToolbox H.264
encode/decode round trip, and one-frame backpressure while the receiver withholds
acknowledgments. See [validation](docs/validation.md) for hardware evidence and
[architecture](docs/architecture.md) for capture and lifecycle behavior.

Extended desktop uses undocumented `CGVirtualDisplay` interfaces isolated in
`Sources/VirtualDisplay`. They are runtime-checked and may change in a future
macOS update. This backend is unsuitable for Mac App Store distribution.
Mirroring uses public capture APIs and does not create a virtual display.

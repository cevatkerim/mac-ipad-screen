# Mac host validation

Date: 2026-09-12. Host: Apple Silicon MacBook Pro, macOS 26.6.2
(Darwin 25.6.0), Xcode's Swift 6.3.3 compiler. Deployment target: macOS 14.0.
Device: iPad Pro 9.7-inch, existing jailbroken iPad Screen companion.

## Automated checks

- Release application builds and passes strict ad-hoc code-signature verification.
- Eight Swift tests pass, including a real VideoToolbox H.264 encode/decode round
  trip with decoded image dimension checks.
- A socket-pair test withholds acknowledgment while capture continues and
  verifies that no second compressed frame is sent until acknowledgment arrives.
- Framing tests reject invalid authentication, empty/oversized/truncated AVCC,
  invalid receiver counters, and malformed usbmux headers.
- Constrained-buffer socket tests preserve two MiB of data and detect truncated
  or cancelled reads. Pairing tests preserve multiple profiles and mode-0600
  token files while rejecting path traversal.

## Hardware observations

- Native USB discovery and SSH pairing succeeded using a dedicated Mac key.
  The existing companion token was imported without replacing the app or token.
- A temporary 2048×1536 display appeared with 1024×768 Retina coordinates.
  Releasing it restored the original active display set.
- The initial moving-pattern run sent and enqueued 225 frames in 15.14 seconds
  with hardware H.264 and zero rendering errors. This exposed avoidable pacing
  loss when waiting for another capture tick after each acknowledgment.
- After processing the latest pending raw frame immediately on acknowledgment,
  desktop mirroring sent and enqueued 572 frames in 20.36 seconds, with hardware
  H.264 and zero renderer errors (about 28 fps including startup).
- GUI inspection found a virtual-display registration race that the initial
  command-line creation check did not expose. Positioning now waits until
  WindowServer publishes the new display to ScreenCaptureKit.
- With that fix, a bounded extended-desktop run sent and enqueued 713 frames in
  26.03 seconds (25 seconds of requested capture plus setup), with hardware H.264
  and zero rendering errors.
- The graphical app correctly surfaces its own Screen Recording permission
  requirement with a direct System Settings button. Permission inherited by a
  command-line invocation does not establish the GUI's capture permission.

These are frame submission/enqueue counters, not measured physical panel
presentation or end-to-end latency. Owner confirmation of visible smoothness,
text quality, sustained thermals, 60 fps, hot unplug, sleep/wake, Intel Macs,
other macOS versions, and other iPad profiles is tracked separately from these
short hardware checks. No private content, identifiers, credentials, screenshots,
or runtime logs are included here.

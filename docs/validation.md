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
- Re-adding the current ad-hoc app to Screen Recording refreshed the stale
  signing entry. The graphical Extend control then streamed 633 frames over
  45.26 seconds with zero errors, including static desktop periods. Stop removed
  the virtual display and left only the original built-in display. A simultaneous
  second CLI session was rejected without disrupting the GUI session.

## Higher frame rates

All measurements below use 2048×1536 and 60 fps requested. Timing values are
averages measured by the Mac; USB time includes the receiver's acknowledgment.
Whole-session rates include startup, and static content reduces submission rate.

| Configuration | Source | Frames / seconds | Average fps | Encode | USB + ack | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| Initial hardware settings | Moving pattern | 666 / 20.18 | 33.0 | 24.4 ms | 4.2 ms | 0 |
| Hardware, speed priority, no frame delay | Desktop mirror | 797 / 20.32 | 39.2 | 19.6 ms | 5.0 ms | 0 |
| Low latency, software RTVC | Desktop mirror | 1144 / 20.80 | 55.0 | 10.3 ms | 4.4 ms | 0 |

The final low-latency mirror run enqueued about 290 frames per five-second
reporting interval (roughly 58 fps during capture). The previous low-latency
moving-pattern runs delivered 1132–1159 frames in roughly 20.7 seconds with no
errors. Apple's `com.apple.videotoolbox.videoencoder.h264.rtvc` reports software
encoding here; the hardware choice uses `com.apple.videotoolbox.videoencoder.ave.avc`.
The UI exposes both choices and reports the actual hardware/software result.
The final graphical Mirror control streamed and enqueued 2629 frames in 46.69
seconds (56.3 fps), with 10.5 ms average encoding, 4.6 ms USB plus acknowledgment,
and zero rendering errors. Its Stop control disconnected cleanly; reconnecting
through Extend at 60 fps with the low-latency encoder also succeeded.

The original bottleneck was encoder turnaround in the serialized encode/send/ack
cycle. The final software path fits most cycles near the 16.7 ms budget for
60 fps, at a CPU tradeoff. Faster-than-60 operation is not implemented. Further
headroom would require overlapping encoding and USB work while preserving a
bounded queue and H.264 dependencies, or reducing the encoded resolution. Bulk
USB bandwidth was not the limiting factor in the low-bitrate pattern runs.

These are frame submission/enqueue counters, not measured physical panel
presentation or end-to-end latency. Owner confirmation of visible smoothness,
text quality, sustained thermals and sustained 60 fps, hot unplug, sleep/wake, Intel Macs,
other macOS versions, and other iPad profiles is tracked separately from these
short hardware checks. No private content, identifiers, credentials, screenshots,
or runtime logs are included here.

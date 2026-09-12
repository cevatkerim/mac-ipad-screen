# Working agreements

- Build the native macOS host against the unchanged iPad Screen protocol in
  docs/protocol.md. Do not describe renderer enqueue counts as presented frames.
- Keep passwords, receiver tokens, device identifiers, keys, screenshots, local
  paths, and runtime logs out of commits. Development state belongs in .runtime/.
- Target only the selected USB iPad. Preserve other apps, keys, and configuration.
- Release only the virtual display owned by the current session when it stops.
- Keep undocumented macOS display interfaces isolated in Sources/VirtualDisplay.
- Commit logical milestones and state what was actually tested on hardware.

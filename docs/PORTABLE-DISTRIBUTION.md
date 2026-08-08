# Portable distribution

## Runtime model

The portable ZIP is runtime-specific (`win-x64` or `win-arm64`) and includes:

- FFmpeg and ffprobe;
- the Python embeddable distribution;
- ffmpeg-normalize and all locked transitive Python packages;
- a startup preflight that verifies architecture, SHA-256, versions,
  required filters/encoders, temporary-directory write access, and free space.

The application launcher prepends only the bundled runtime directories for the
child process. It does not install Python, modify the machine-wide `PATH`, or
write registry settings.

## Build and update policy

Dependency versions, URLs, licenses, and SHA-256 values are locked in
`portable-dependencies.json`. Updating a dependency requires updating that
file, rebuilding both runtimes, and running the portable integration tests.

## Publication gate

The generated ZIP is not code-signed. Do not represent it as signed or
SmartScreen-trusted.

Before public distribution:

1. obtain a suitable Windows code-signing certificate or choose a Store/MSIX
   distribution route;
2. publish ZIP checksums over HTTPS;
3. retain all notices and license files;
4. host the exact corresponding FFmpeg/build source beside the binary download
   because the bundled FFmpeg build enables GPL components including libx264;
5. review the GPL-licensed Mutagen dependency and the aggregate distribution
   with qualified legal counsel.

This document records a release gate and is not legal advice.

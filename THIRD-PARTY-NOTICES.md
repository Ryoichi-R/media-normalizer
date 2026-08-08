# Third-party notices

The portable Media Normalizer package contains third-party executables and
Python packages. Exact versions, download URLs, and SHA-256 values are recorded
in `runtime/dependency-manifest.json`.

## FFmpeg

- Version: 8.1.2-31-g8c9502e9b0
- Binary provider: BtbN/FFmpeg-Builds
- License of the bundled build: GPL-3.0-or-later
- FFmpeg source: <https://github.com/FFmpeg/FFmpeg/tree/8c9502e9b0>
- Build recipe source: <https://github.com/BtbN/FFmpeg-Builds/tree/8c736b2>

The selected build enables GPL components including libx264. Anyone
redistributing the portable ZIP must also satisfy the applicable GPL source
code and license-notice requirements. Keep the FFmpeg license and build
information included under `runtime/licenses/FFmpeg/`, and make the exact
corresponding source available from the same distribution location.

## Embedded Python

- Version: 3.13.14
- License: PSF License Version 2
- Source and release information:
  <https://www.python.org/downloads/release/python-31314/>

The Python license is included under `runtime/licenses/Python/`.

## Python packages

- ffmpeg-normalize 1.41.1 — MIT
- tqdm 4.69.1 — MPL-2.0 AND MIT
- colorama 0.4.6 — BSD-3-Clause
- ffmpeg-progress-yield 1.1.3 — MIT
- colorlog 6.7.0 — MIT
- mutagen 1.48.1 — GPL-2.0-or-later

Package license files are retained inside the corresponding `.dist-info`
directories under `runtime/python/Lib/site-packages/`.

This notice is an engineering inventory, not legal advice.

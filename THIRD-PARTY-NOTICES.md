# Third-party notices

The portable Media Normalizer package contains third-party executables and
Python packages. Exact versions, download URLs, and SHA-256 values are recorded
in `runtime/dependency-manifest.json`.

## FFmpeg

- Version: 8.1.2-34-g9b6c8969e0
- Binary provider: BtbN/FFmpeg-Builds
- License of the bundled build: GPL-3.0-or-later
- FFmpeg source: <https://github.com/FFmpeg/FFmpeg/tree/9b6c8969e0>
- Build recipe source: <https://github.com/BtbN/FFmpeg-Builds/tree/a99e8230eae00d1cee38f23076a7a1f55cd984e2>

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

## macOS arm64 runtime pins

- FFmpeg and ffprobe 8.1.2 — Martin Riedl macOS arm64 build; GPL-3.0-or-later. The measured archive URLs and SHA-256 values are in `portable-dependencies.json`. The build configuration enables GPL and version 3 components, including libx264. Any future transfer of these binaries to another person requires a separate review of the corresponding-source and notice terms.
- Python 3.13.15 — python-build-standalone release 20260924; PSF-2.0. Keep the archive license and notices with the full runtime tree.
- PowerShell 7.6.6 — Microsoft official macOS arm64 binary archive; MIT. Keep `LICENSE.txt` and `ThirdPartyNotices.txt` from the full archive with the runtime.

The six locked Python wheels retain their existing versions, hashes, and license inventory above. Ad-hoc signing changes the Mach-O bytes and does not replace upstream license notices or imply Apple Developer ID signing or notarization.

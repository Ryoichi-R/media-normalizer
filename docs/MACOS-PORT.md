# macOS Apple Silicon port

Updated: 2026-09-28 (Asia/Tokyo)

This document records the staged macOS port. The supported target is Apple Silicon (`osx-arm64`). The Windows WinForms application remains intact during the migration.

## Phase 0: dependency and platform findings

### Locked runtime candidates

The following archives were downloaded to a temporary validation directory and their SHA-256 values were compared with the distributor's sidecar or official release metadata on 2026-09-27. The archive files are not stored in the repository.

| Component | Pinned build | Archive SHA-256 | Evidence |
| --- | --- | --- | --- |
| FFmpeg | 8.1.2, macOS arm64 | `ef1aa60006c7b77ce170c1608c08d8e4ba1c30c5746f2ac986ded932d0ac2c3c` | Provider sidecar; `-version` reports 8.1.2 |
| ffprobe | 8.1.2, macOS arm64 | `c39787f4af7a3932502d2d48db6f6feaaa836b48a73ef78c32cc3285df61dfaf` | Provider sidecar |
| CPython | 3.13.15, python-build-standalone tag `20260924` | `a18e1d1b6067d39cf7b2b605fdb78ad6b8a3aed221c44ef934d399dccf355453` | GitHub release asset digest |
| PowerShell | 7.6.6, official macOS arm64 binary archive | `6df833d094ebac1c1a74340d7b3437f4aaf5e03ce640484a1c4359f3ce8b3db1` | GitHub release asset digest |

FFmpeg URLs and all pin values are in `portable-dependencies.json`. FFmpeg 8.1.2 matches the Windows pin's upstream version. The tested binary reports the `loudnorm` filter and includes `libx264`, `libmp3lame`, AAC, ALAC, and PCM encoders. Its build configuration contains `--enable-gpl` and `--enable-version3`, so this build is GPL-3.0-or-later. FFmpeg's own licensing page explains that enabling GPL components changes the applicable FFmpeg license; this project does not distribute the macOS bundle to other people. Reassess source and notice obligations before any transfer or publication: https://www.ffmpeg.org/legal.html

The FFmpeg provider's page says macOS ZIP binaries are signed and installer packages are notarized. On the downloaded, hash-matched ZIP executables, `codesign --verify --strict` failed for both `ffmpeg` and `ffprobe` with an invalid-signature result. Treat the provider's signing statement as unverified for these ZIP binaries. The PowerShell archive executable also failed local code-signature verification. The Python executable passed. The bundle PoC therefore records upstream archive hashes independently and uses the plan's internal ad-hoc re-signing flow; it does not claim the upstream signatures are valid.

The PowerShell archive includes `LICENSE.txt` and `ThirdPartyNotices.txt`; preserve both. The Python archive includes `python/lib/python3.13/LICENSE.txt`. The six existing Python wheels were independently downloaded and matched to their locked hashes. Their embedded wheel tags were `py3-none-any` or `py2.py3-none-any`; `mutagen` remains GPL-2.0-or-later. Installing those locked wheels into the extracted Python runtime succeeded, and importing `ffmpeg_normalize`, `ffmpeg_progress_yield`, `colorlog`, and `mutagen` succeeded.

### Platform and architecture checks

The downloaded FFmpeg, ffprobe, PowerShell, and Python entry binaries were thin 64-bit Mach-O files. Reading the Mach-O header's `cputype` produced `0x0100000c` (arm64) for each. `otool` reported minimum OS values of macOS 12.0 for FFmpeg and PowerShell and 11.0 for the Python executable. Microsoft documentation lists macOS 15 as the oldest currently supported OS for PowerShell 7.6; .NET 10 lists macOS 14, 15, and 26. Set the product minimum to macOS 15.0 and recheck the official matrices before a release. The current development host is macOS 27 on Apple Silicon; that host is useful for smoke checks but does not expand the documented support matrix.

Microsoft PowerShell for macOS: https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-macos
.NET for macOS: https://learn.microsoft.com/en-us/dotnet/core/install/macos
python-build-standalone distribution documentation: https://github.com/astral-sh/python-build-standalone/blob/main/docs/running.rst

### Avalonia PoC fixture

`tests/support/fixtures/macos-poc-bundle/` contains a minimal Avalonia 11.3.20 window and a safe `.app` layout generator. Build an arm64 self-contained publish into a new temporary directory, then pass that directory and a new `.app` path to `Build-PocBundle.ps1`. The generator refuses to overwrite an existing path. `Info.plist` declares macOS 15.0 as the minimum.

For a PoC-only local signing check, sign nested Mach-O files from deepest path to shallowest path with `codesign --force --sign - --timestamp=none`, create a test manifest from the post-signature SHA-256 values, then sign the outer PoC `.app` and run `codesign --verify --deep --strict`. The manifest must be regenerated after any re-signing. To test quarantine handling, apply a quarantine attribute only to the temporary PoC `.app`, remove it from that same normalized absolute `.app` path, and confirm a sibling test file retains its attribute. Do not apply this test to a parent directory or workspace.

### Phase 0 gate

The macOS runtime archive, architecture, package-tag, Core import, and Avalonia PoC checks are recorded above. On the macOS 27 Apple Silicon development host, the PoC was published as an arm64 self-contained app, nested Mach-O files were ad-hoc signed, the post-signature manifest was generated, and the outer app passed `codesign --verify --deep --strict`. LaunchServices `open -n -W` launched the app and it remained alive during the smoke check. The test processes were stopped afterward. The quarantine isolation check was also completed on this temporary app: a quarantine attribute was applied to the app and a temporary sibling file, removed only from the normalized app path, and verified to remain on the sibling. `codesign --verify --deep --strict` still passed afterward. P0-7 is complete for this PoC fixture; this is not a distribution notarization test.

On 2026-09-28 the owner explicitly removed Windows/macOS comparison from the current work and requested continued implementation on Mac. P0-8 is not performed and no longer blocks implementation of later phases. Cross-OS numeric equivalence and Windows regression remain unverified; neither is recorded as passed.

The comparison starter-kit sources remain available, but no Windows handoff or comparison is required for the current implementation work.

## Implementation status

### Phase 1: platform seam and contracts

- Added `lib/MediaNormalizer.Platform.psm1` for OS/architecture detection, executable/runtime resolution, platform storage paths, bundle-path write protection, and POSIX process-tree termination.
- Extracted platform-neutral UI logic into `lib/MediaNormalizer.UiLogic.psm1`; the WinForms module imports and re-exports it.
- Added non-Windows import and macOS path/Mach-O checks, plus machine-readable settings schema, fixtures, and contract tests.
- The settings contract permits additive fields. The owner approved preserving unknown JSON fields on schema-compatible read/write round-trips so compatible frontends and versions do not erase extensions when they read and write the same file. Unsupported future schema versions still fall back to defaults under the existing version policy.
- Windows full-suite and Ubuntu 24.04 validation were unavailable on this host. Phase 1 is not recorded as complete.

### Phase 2: CLI/runtime/process foundations

- Added cross-platform resolution for pinned FFmpeg/ffprobe/Python/PowerShell tools and macOS arm64 dependency pins.
- Added a POSIX process runner using argument arrays, redirected output, FFmpeg progress and heartbeat handling, exit status propagation, and process-tree cancellation. If the root process cannot be observed after termination, the runner fails closed and retains logs.
- Added run-recovery schema/fixtures and atomic recovery records with exclusive locks; wired the guard into the macOS CLI path. This is CLI recovery scaffolding, not the Avalonia host or worker service.
- Kept the Windows `Start-Process` path and WinForms application in place. Added `.app/Contents` output protection and platform-specific relative-path handling.

### Phase 4: event-stream and worker foundation (partial)

- Added the optional `-EventSink` to `Invoke-Normalize` for `run-start`, `file-start`, `progress`, `log`, `file-done`, `run-done`, and `error` events. A regression test compares the existing logger text with and without the sink.
- Added `contracts/worker-protocol.schema.json`, canonical command/event fixtures, and dependency-free PowerShell and C# validators. The contract includes process-starting/started/exited messages, process-registration acknowledgements, and temporary-output registration.
- Added Core process and temporary-output registration gates for worker-mode state. Core persists a start intent before spawning, then emits the child PID and start time and waits for an identity-matched host ACK. It also waits for host registration before writing run-scoped intermediate output. Rejection, mismatch, cancellation, or timeout fails closed.
- Added `scripts/mn-worker.ps1` with `capabilities`, `scan`, and `normalize` commands, NDJSON events, an asynchronously pumped stdin control channel for cancellation and process-registration ACKs, and the normalization job lock. The worker imports Core directly and does not pass through `media-normalizer.ps1`.
- Added worker-entry tests for capabilities, Core-based scan classification, invalid commands, and job-lock conflict. Fixed logger-prefix to protocol-level mapping and added a regression test for `[WARN ]`, `[ERROR]`, `[DEBUG]`, and `[INFO ]`.
- Added a dependency-free `net10.0` `WorkerSupervisor` service and console harness. The service persists host/worker/process identities, validates NDJSON fields and types, verifies PID/start-time pairs, monitors descendants, and distinguishes a concurrent job (`JOB_ALREADY_RUNNING`, exit 3) from an unresolved recovery (`RECOVERY_REQUIRED`, exit 4).
- Added host-startup recovery for valid GUI run records: stop verified descendants using TERM then KILL, reacquire the normalization job lock, remove only registered run-scoped files, and mark the record complete only after cleanup. Invalid identities, unresolved process-start intents, lock conflicts, and unsafe paths remain blocked for diagnosis.
- The harness exercises real worker capabilities and process registration, job-conflict exit 3, incomplete-stream handling, worker `RECOVERY_REQUIRED` exit 4, worker nonzero exit, a TERM-resistant descendant requiring KILL, registered temporary-file cleanup, recovery from a persisted run after host restart, and fail-closed suppression when a process start has no matching acknowledgement. It does not launch or kill an Avalonia host; that integration belongs to the later GUI phase.
- Phase 4 remains partial: the Windows output-regression gate is unavailable here, and the Avalonia host is not yet integrated. The owner decision above permits further Mac implementation.

### Phase 5: settings persistence foundation (partial)

- Added `src/MediaNormalizer.Gui/Services/SettingsStore.cs` with Windows, macOS, and Linux per-user paths matching `Get-MediaNormalizerStoragePath`, schema v2 values, additive extension-field retention, v1 automatic-path migration, and existing malformed/future-version fallback behavior.
- Added `tests/support/SettingsStoreHarness/` to exercise the C# store against the same settings fixtures used by PowerShell. It checks nested unknown-field round-trip, known-field updates, defaults, malformed/missing/future versions, v1 migration, and default-path resolution.
- This is the persistence service only. It is not yet connected to an Avalonia host or UI; Phase 5 remains incomplete.

### Validation on macOS 27 Apple Silicon

The following unit command completed successfully on 2026-09-27:

```powershell
pwsh -NoLogo -NoProfile -Command '$c=New-PesterConfiguration; $c.Run.Path="tests/unit"; $c.Filter.ExcludeTag=@("WindowsOnly"); $c.Output.Verbosity="Normal"; Invoke-Pester -Configuration $c'
```

Result: 311 tests discovered across 41 files; 278 passed, 0 failed, and 33 were not run because they are tagged `WindowsOnly`. The targeted Phase 4 suite passed 41 tests with 0 failures. The `WorkerSupervisorHarness` build completed with 0 warnings and 0 errors, and its macOS run passed the worker protocol, job-conflict exit 3, incomplete-stream handling, `RECOVERY_REQUIRED` exit 4, in-host recovery, host-restart recovery, TERM/KILL, cleanup, and suppression checks. All 34 contract and fixture JSON files parsed, and PowerShell parsing passed for the four changed runtime entry/module files. `git -c core.whitespace=cr-at-eol diff --check` passed. The repository's `scripts/check-module-toplevel.ps1` and `.config/formatter/` are absent, so those workspace-wide checks are unavailable in this standalone repository. These results do not substitute for the plan's Windows suite, Ubuntu 24.04 import run, or P0-8 comparison.

Settings v2 now retains additive unknown fields in both the PowerShell implementation and the C# `SettingsStore`; PowerShell and C# tests use shared fixtures. Unsupported future schema versions still fall back to defaults under the existing version policy. P0-8 is excluded by the owner decision above; Mac implementation continues.

## 2026-09-28: bundled macOS CLI

`prepare-portable-runtime.ps1 -Runtime osx-arm64` now downloads the already pinned FFmpeg, ffprobe, Python, PowerShell and pure Python wheels, verifies archive hashes, preserves runtime notices, signs native binaries locally, and writes post-signature critical-file hashes. The archive pins remain independent of those hashes. The full PowerShell archive is retained.

Build a CLI-only package on an Apple Silicon Mac with build-time PowerShell:

```powershell
pwsh -NoProfile -File scripts/build-media-normalizer-cli-package.ps1 -OutputRoot <new-package-directory> -CacheRoot <dependency-cache-directory>
```

The output directory must not already exist. A failed build remains available for diagnosis; use a new output directory for a retry. The generated package contains `media-normalizer.sh`, `runtime-check.sh`, and `diagnose.sh`. Run `./media-normalizer.sh -InputPath <media> -OutputDir <output>` for normalization, optionally adding `-Mode video` or `-AnalyzeOnly`. The shell entrypoint selects CLI mode automatically. This package does not yet contain the Avalonia GUI or a Finder `.app`.

The bootstrap validates the bundled PowerShell hash before executing it. The shared PowerShell runtime diagnostic then checks required manifest entries, hashes, root-contained symbolic links, arm64 Mach-O headers, executable permissions, pinned versions, Python package import, loudnorm, required encoders, and temporary-volume write access/free space. Failure prevents CLI startup; no PATH fallback is used. Python user-site loading and bytecode writes are disabled in these child processes.

Real CLI startup exposed forced nested Platform module imports removing commands from the entrypoint, which also bypassed its macOS job/recovery lock. Core, Probe, UiLogic, and RunRecovery now import their common dependency without forcing its removal. A fresh-process regression checks that all entrypoint platform commands survive these imports.

Mac verification on 2026-09-28: the generated runtime passed diagnostic checks after local signing; 30 critical-file hashes were recorded. Shell startup succeeded with development PowerShell absent from PATH and after relocating the package to a path containing Japanese text and spaces. WAV, FLAC, MP3, M4A, MP4 and multistream MKV normalized successfully. The MKV output retained video=1, audio=2, subtitle=1 and chapters=2. Both-mode analysis reported seven analyzed files and one expected corrupt-input failure. Real-runtime hash corruption was rejected. Bootstrap/build-helper/download tests and the related import, command-resolution, recovery, settings, Core and worker tests passed (61 distinct tests). These are Mac results only.

Phase 3 packaging integration with the existing Windows artifact/build-contract entrypoints remains unfinished. Avalonia presentation, completed `.app` packaging, activation and full acceptance work also remain. The existing Windows artifact pipeline has not been declared verified by these checks.


## 2026-09-29: Avalonia app

This section supersedes earlier statements that GUI and app packaging are unimplemented.

### Build and run

On an Apple Silicon Mac with build-time .NET 10 SDK and PowerShell:

```powershell
pwsh -NoProfile -File scripts/rebuild-media-normalizer.ps1 -Runtime osx-arm64 -OutputRoot <new-output-directory>
```

For an already verified prepared runtime, add `-PreparedRuntimeRoot <runtime-directory>`.
Archive pins and Python package versions/hashes must match `portable-dependencies.json`.
The output app must not already exist. Failed outputs are retained; retry in a new directory.
NuGet dependencies use `packages.lock.json` and locked restore. Build telemetry is disabled.

Open `Media Normalizer.app` from Finder. The thin `Contents/MacOS/media-normalizer` launcher
starts the self-contained host under `Contents/Resources/gui`; the latter location avoids
treating managed DLLs as nested native code during bundle signing. CLI usage is also available:

```sh
"Media Normalizer.app/Contents/Resources/media-normalizer.sh" -InputPath <media> -OutputDir <output>
```

The app includes input pickers, drag/drop, Core-backed scan, per-file selection and speed,
mode/format/target/peak settings, presets and rationale/current-value match, analysis-only,
recursive discovery, preserved hierarchy, collision policy, confirmation, progress/ETA,
cancellation, and bounded persistent logs. Selection and individual speed survive rescans;
changing global speed applies the new speed on the next scan. User presets are merged by name
from `~/Library/Application Support/media-normalizer/presets.user.json`.

Settings use the shared v2 contract and retain unknown fields. User state and locks are under
`~/Library/Application Support/media-normalizer`; logs are under
`~/Library/Logs/media-normalizer`. No mutable app data is stored in `Contents`.
Tests may inject an isolated directory through `--storage-root`.

### Signing and integrity

Pinned upstream archives are hash-verified before extraction. Native runtime binaries are
ad-hoc signed before critical-file hashes are recorded in the dependency manifest. Published
native GUI files and then the outer app are signed. Prepared runtime signatures are preserved;
upstream bytecode caches are removed only from the newly copied runtime. The build runs
`codesign --verify --deep --strict`, the shared runtime diagnostic, and the app privacy gate.
Ad-hoc signing is for this local build; Developer ID signing/notarization is not provided.

`build-media-normalizer-app-bundle.ps1 -RemoveQuarantine` applies `xattr -dr` only to the
normalized, newly built `.app` path. It does not change parent/sibling folders. The normal
build leaves quarantine unchanged. Finder quarantine behavior still needs manual acceptance.

```powershell
pwsh -File scripts/test-artifact-integrity.ps1 -AppPath <app>
pwsh -File scripts/test-zip-privacy.ps1 -AppPath <app>
pwsh -File scripts/test-zip-privacy.ps1 -ZipPath <mac-zip> -MacArchive
```

The Mac scanners reject local user paths, state/log/bytecode files, secret-like filenames,
unsafe archive paths and escaping symlinks. Reviewed upstream build paths/examples are
allowed only at exact paths with exact SHA-256 values in `macos-privacy-baseline.json`.
The Python standard-library `secrets.py` and public certifi CA bundle are likewise exact-hash
exceptions; they are not user credentials. The current user's home path is always rejected.

### Acceptance evidence and remaining limits

On 2026-09-29, the macOS unit suite passed 286 tests (33 Windows-only tests excluded), and
12 CLI bootstrap/runtime-build integration tests passed. SettingsStore round-trip and
WorkerSupervisor recovery harnesses passed. Avalonia.Headless exercised actual bundled
normalization, cancellation/recovery, scan invalidation, selection retention, user presets,
settings, missing-runtime refusal, valid/malformed activation, mismatched instance/version,
timeout, stale endpoint and concurrent startup. The GUI build has zero warnings/errors.
A self-contained native launch without development tools on PATH and direct second-launch
ACK succeeded. Final app and ZIP integrity/privacy checks succeeded.

Cancellation arriving before process-registration ACK is deferred until registration finishes;
then Core stops the process and emits its exit identity. This avoids an unverified-exit recovery
block. Recovery retains fail-closed behavior for missing/rejected ACK or unknown process identity.

Finder/Dock minimize/foreground behavior has a handler but remains visually unverified:
the native UI automation tool timed out while selecting this app. Headless rendered layout
was inspected. Full host-kill-during-descendant-creation acceptance, long/HDR input matrix,
macOS 15 runtime acceptance, Windows regression and cross-OS numeric comparison are not
claimed complete. The owner excluded the cross-OS comparison from this implementation.
Workspace formatter/lint entrypoints reject this external standalone project; their invocation
failed at inventory resolution. C# warning-as-error builds and PowerShell unit checks succeeded.

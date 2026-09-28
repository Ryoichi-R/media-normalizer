# macOS Apple Silicon port

Updated: 2026-09-27 (Asia/Tokyo)

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

P0-8's same-fixture Windows/macOS report comparison remains open because this host has no Windows runtime. The plan requires both fixed FFmpeg builds to run on their native systems. Phase 0 is therefore incomplete. The plan's R9 explicitly allows Phase 4 implementation to proceed before this comparison; Phase 3 and later product acceptance remain gated on P0-8. Phases 1 and 2 were implemented only to the extent allowed by their own stop conditions; their Windows and Ubuntu validation gates remain open.

`docs/FFMPEG-COMPARISON-SAMPLE.md` now describes a P0-8 starter kit: an eight-file synthetic corpus generator, a cross-machine SHA-256 verifier, and a blank report-comparison receipt. The current shell has no FFmpeg executable on PATH, so the binary corpus and measurement receipt were not generated here. Generate it once with the pinned binary, copy it unchanged to both systems, then verify the hashes before collecting reports.

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
- Phase 4 remains partial: the Windows output-regression gate is unavailable here, and the Avalonia host is not yet integrated. The plan's R9 permits this Phase 4 implementation before P0-8, while Phase 3 and later product acceptance remain gated.

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

Settings v2 now retains additive unknown fields in both the PowerShell implementation and the C# `SettingsStore`; PowerShell and C# tests use shared fixtures. Unsupported future schema versions still fall back to defaults under the existing version policy. P0-8 remains open because no Windows runtime is available on this host; Phase 3 and later remain gated on that comparison.

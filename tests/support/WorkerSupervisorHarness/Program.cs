using System.Diagnostics;
using System.Text.Json;
using MediaNormalizer.Gui.Services;

if (args.Length != 3)
{
    Console.Error.WriteLine("Usage: WorkerSupervisorHarness <repo-root> <pwsh-path> <temp-root>");
    return 2;
}

var repoRoot = Path.GetFullPath(args[0]);
var pwshPath = Path.GetFullPath(args[1]);
var tempRoot = Path.GetFullPath(args[2]);
var workerPath = Path.Combine(repoRoot, "scripts", "mn-worker.ps1");
Directory.CreateDirectory(tempRoot);
var observedEvents = new List<string>();
using var supervisor = new WorkerSupervisor(tempRoot, pwshPath, workerPath, message =>
{
    observedEvents.Add(message.GetProperty("type").GetString() ?? string.Empty);
    if (message.GetProperty("type").GetString() == "error")
    {
        Console.Error.WriteLine(message.GetRawText());
    }
});

var capabilities = await supervisor.RunAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
{
    ["schemaVersion"] = 1,
    ["id"] = Guid.NewGuid().ToString("D"),
    ["cmd"] = "capabilities"
});
if (capabilities.ExitCode != 0 || capabilities.RecoveryRequired || !observedEvents.Contains("capabilities-result", StringComparer.Ordinal))
{
    Console.Error.WriteLine($"Capabilities failed: exit={capabilities.ExitCode}, recovery={capabilities.RecoveryRequired}, stderr={capabilities.StandardError}");
    return 1;
}

var recordPath = Path.Combine(tempRoot, "run", "active-run.json");
using (var record = JsonDocument.Parse(await File.ReadAllTextAsync(recordPath)))
{
    var root = record.RootElement;
    if (root.GetProperty("schemaVersion").GetInt32() != 2 || root.GetProperty("entrypoint").GetString() != "gui" ||
        root.GetProperty("status").GetString() != "completed")
    {
        Console.Error.WriteLine("Capabilities did not write a completed GUI host record.");
        return 1;
    }
}

var jobLockPath = Path.Combine(tempRoot, "run", "normalization-job.lock");
await using (var heldJobLock = new FileStream(jobLockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
{
    var conflictResult = await supervisor.RunAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
    {
        ["schemaVersion"] = 1,
        ["id"] = Guid.NewGuid().ToString("D"),
        ["cmd"] = "normalize",
        ["runId"] = Guid.NewGuid().ToString("D"),
        ["inputPaths"] = new[] { tempRoot },
        ["outputDir"] = Path.Combine(tempRoot, "output"),
        ["mode"] = "audio",
        ["target"] = -16.0,
        ["truePeak"] = -1.0,
        ["bitrate"] = "192k",
        ["sampleRate"] = "44100",
        ["collisionPolicy"] = "rename",
        ["speedPercent"] = 100,
        ["audioOutputFormat"] = "mp3",
        ["analyzeOnly"] = false,
        ["skipIfNormalized"] = true,
        ["normalizationTolerance"] = 0.5,
        ["recurse"] = true,
        ["preserveHierarchy"] = true
    });
    if (conflictResult.ExitCode != 3 || conflictResult.RecoveryRequired)
    {
        Console.Error.WriteLine($"Job conflict was not distinguished from recovery: exit={conflictResult.ExitCode}, recovery={conflictResult.RecoveryRequired}, stderr={conflictResult.StandardError}");
        return 1;
    }
}

var truncatedWorkerPath = Path.Combine(tempRoot, "truncated-worker.ps1");
await File.WriteAllTextAsync(truncatedWorkerPath, """
$command = [Console]::In.ReadLine() | ConvertFrom-Json -AsHashtable
$event = [ordered]@{ schemaVersion = 1; type = 'run-start'; runId = $command.runId; mode = 'audio' }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $event -Compress)); [Console]::Out.Flush()
exit 0
""");
using var truncatedSupervisor = new WorkerSupervisor(tempRoot, pwshPath, truncatedWorkerPath);
var truncatedResult = await truncatedSupervisor.RunAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
{
    ["schemaVersion"] = 1,
    ["id"] = Guid.NewGuid().ToString("D"),
    ["cmd"] = "normalize",
    ["runId"] = Guid.NewGuid().ToString("D"),
    ["mode"] = "audio"
});
if (truncatedResult.ExitCode != 1 || truncatedResult.RecoveryRequired)
{
    Console.Error.WriteLine($"A stream ending before run-done was not treated as an incomplete run: exit={truncatedResult.ExitCode}, recovery={truncatedResult.RecoveryRequired}");
    return 1;
}

var recoveryErrorRoot = Path.Combine(tempRoot, "recovery-error-root");
Directory.CreateDirectory(recoveryErrorRoot);
var recoveryErrorWorkerPath = Path.Combine(recoveryErrorRoot, "recovery-error-worker.ps1");
await File.WriteAllTextAsync(recoveryErrorWorkerPath, """
$command = [Console]::In.ReadLine() | ConvertFrom-Json -AsHashtable
$event = [ordered]@{ schemaVersion = 1; type = 'error'; runId = $command.runId; code = 'RECOVERY_REQUIRED'; message = 'synthetic fail-closed condition' }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $event -Compress)); [Console]::Out.Flush()
exit 4
""");
using var recoveryErrorSupervisor = new WorkerSupervisor(recoveryErrorRoot, pwshPath, recoveryErrorWorkerPath);
var recoveryErrorResult = await recoveryErrorSupervisor.RunAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
{
    ["schemaVersion"] = 1,
    ["id"] = Guid.NewGuid().ToString("D"),
    ["cmd"] = "normalize",
    ["runId"] = Guid.NewGuid().ToString("D"),
    ["mode"] = "audio"
});
if (recoveryErrorResult.ExitCode != 4 || !recoveryErrorResult.RecoveryRequired)
{
    Console.Error.WriteLine($"Worker RECOVERY_REQUIRED was not kept fail-closed: exit={recoveryErrorResult.ExitCode}, recovery={recoveryErrorResult.RecoveryRequired}");
    return 1;
}

if (!OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux())
{
    Console.WriteLine("Worker capabilities passed; POSIX orphan-process recovery was skipped on this OS.");
    return 0;
}

var pidPath = Path.Combine(tempRoot, "orphan.pid");
var temporaryPathFile = Path.Combine(tempRoot, "registered-temp-path.txt");
var fakeWorkerPath = Path.Combine(tempRoot, "fake-worker.ps1");
var fakeWorker = $$"""
$ErrorActionPreference = 'Stop'
$command = [Console]::In.ReadLine() | ConvertFrom-Json -AsHashtable
$tempDirectory = [IO.Path]::GetDirectoryName('{{temporaryPathFile.Replace("'", "''")}}')
$temporaryPath = Join-Path $tempDirectory (".sample.media-normalizer-$($command.runId)-$([guid]::NewGuid().ToString('N')).flac")
$finalPath = Join-Path $tempDirectory 'sample.flac'
$temporaryEvent = [ordered]@{ schemaVersion = 1; type = 'temporary-output'; runId = $command.runId; inputPath = '/input/sample.wav'; temporaryPath = $temporaryPath; finalPath = $finalPath; role = 'primary' }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $temporaryEvent -Depth 8 -Compress)); [Console]::Out.Flush()
$temporaryAck = [Console]::In.ReadLine() | ConvertFrom-Json -AsHashtable
if ($temporaryAck.cmd -ne 'temporary-file-registration-ack' -or -not $temporaryAck.accepted) { exit 4 }
[IO.File]::WriteAllText($temporaryPath, 'temporary output')
[IO.File]::WriteAllText('{{temporaryPathFile.Replace("'", "''")}}', $temporaryPath)
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = '/bin/sh'
$startInfo.ArgumentList.Add('-c')
$startInfo.ArgumentList.Add('trap "" TERM; while :; do sleep 30; done')
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$child = [Diagnostics.Process]::new()
$child.StartInfo = $startInfo
[void]$child.Start()
[IO.File]::WriteAllText('{{pidPath.Replace("'", "''")}}', [string]$child.Id)
$token = [guid]::NewGuid().ToString('D')
$parent = [Diagnostics.Process]::GetCurrentProcess()
$parentStart = [DateTimeOffset]::new($parent.StartTime.ToUniversalTime()).ToString('o')
$childStart = [DateTimeOffset]::new($child.StartTime.ToUniversalTime()).ToString('o')
$starting = [ordered]@{ schemaVersion = 1; type = 'process-starting'; runId = $command.runId; processToken = $token; executablePath = '/bin/sh'; arguments = @('-c', 'sleep 30 & wait'); parentProcessId = $PID; parentStartedAtUtc = $parentStart }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $starting -Depth 8 -Compress)); [Console]::Out.Flush()
$started = [ordered]@{ schemaVersion = 1; type = 'process-started'; runId = $command.runId; processToken = $token; processId = $child.Id; processStartedAtUtc = $childStart; executablePath = '/bin/sh'; parentProcessId = $PID; parentStartedAtUtc = $parentStart }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $started -Depth 8 -Compress)); [Console]::Out.Flush()
$ack = [Console]::In.ReadLine() | ConvertFrom-Json -AsHashtable
if ($ack.cmd -ne 'process-registration-ack' -or -not $ack.accepted) { exit 4 }
exit 17
""";
await File.WriteAllTextAsync(fakeWorkerPath, fakeWorker);
using var recoverySupervisor = new WorkerSupervisor(tempRoot, pwshPath, fakeWorkerPath);
var recoveryResult = await recoverySupervisor.RunAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
{
    ["schemaVersion"] = 1,
    ["id"] = Guid.NewGuid().ToString("D"),
    ["cmd"] = "normalize",
    ["runId"] = Guid.NewGuid().ToString("D")
});
if (recoveryResult.ExitCode != 17 || recoveryResult.RecoveryRequired)
{
    using var failureRecord = JsonDocument.Parse(await File.ReadAllTextAsync(recordPath));
    var recoveryMessage = failureRecord.RootElement.GetProperty("recoveryMessage").GetString();
    Console.Error.WriteLine($"Worker recovery failed: exit={recoveryResult.ExitCode}, recovery={recoveryResult.RecoveryRequired}, stderr={recoveryResult.StandardError}, detail={recoveryMessage}");
    return 1;
}

var orphanPid = int.Parse(await File.ReadAllTextAsync(pidPath), System.Globalization.CultureInfo.InvariantCulture);
var registeredTemporaryPath = await File.ReadAllTextAsync(temporaryPathFile);
if (File.Exists(registeredTemporaryPath))
{
    Console.Error.WriteLine("The run-scoped intermediate file was not cleaned after process recovery.");
    return 1;
}
var orphanStillAlive = false;
try
{
    using var orphan = Process.GetProcessById(orphanPid);
    orphanStillAlive = !orphan.HasExited;
}
catch (ArgumentException)
{
    orphanStillAlive = false;
}
if (orphanStillAlive)
{
    Console.Error.WriteLine($"The registered orphan process remains alive: {orphanPid}");
    return 1;
}

using (var record = JsonDocument.Parse(await File.ReadAllTextAsync(recordPath)))
{
    var root = record.RootElement;
    var processes = root.GetProperty("processes");
    if (root.GetProperty("status").GetString() != "completed" || processes.GetArrayLength() < 2 ||
        root.GetProperty("intermediatePaths").GetArrayLength() != 0)
    {
        Console.Error.WriteLine("Recovery did not persist the process tree and completed status.");
        return 1;
    }
    foreach (var identity in processes.EnumerateArray())
    {
        var processId = identity.GetProperty("processId").GetInt32();
        try
        {
            using var tracked = Process.GetProcessById(processId);
            if (!tracked.HasExited)
            {
                Console.Error.WriteLine($"A registered process remains alive: {processId}");
                return 1;
            }
        }
        catch (ArgumentException)
        {
            // The tracked process has exited.
        }
    }
}

var restartRunId = Guid.NewGuid().ToString("D");
var restartTemporaryPath = Path.Combine(tempRoot, $"sample.media-normalizer-{restartRunId}-{Guid.NewGuid():N}.tmp");
await File.WriteAllTextAsync(restartTemporaryPath, "registered before host restart");
var abandonedWorker = new Process
{
    StartInfo = new ProcessStartInfo
    {
        FileName = "/bin/sh",
        UseShellExecute = false,
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true
    }
};
abandonedWorker.StartInfo.ArgumentList.Add("-c");
abandonedWorker.StartInfo.ArgumentList.Add("sleep 30 & wait");
if (!abandonedWorker.Start())
{
    Console.Error.WriteLine("Could not start the restart-recovery process fixture.");
    return 1;
}
await Task.Delay(TimeSpan.FromMilliseconds(150));
var abandonedStart = new DateTimeOffset(abandonedWorker.StartTime.ToUniversalTime());
var pendingRecoveryRecord = new Dictionary<string, object?>(StringComparer.Ordinal)
{
    ["schemaVersion"] = 2,
    ["runId"] = restartRunId,
    ["entrypoint"] = "gui",
    ["status"] = "running",
    ["ownerProcessId"] = Environment.ProcessId,
    ["startedAtUtc"] = DateTimeOffset.UtcNow,
    ["updatedAtUtc"] = DateTimeOffset.UtcNow,
    ["resultCode"] = null,
    ["hostStartedAtUtc"] = DateTimeOffset.UtcNow,
    ["workerProcessId"] = null,
    ["workerStartedAtUtc"] = null,
    ["processes"] = new[]
    {
        new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["processId"] = abandonedWorker.Id,
            ["parentProcessId"] = Environment.ProcessId,
            ["startedAtUtc"] = abandonedStart,
            ["processToken"] = Guid.NewGuid().ToString("D"),
            ["executablePath"] = "/bin/sh"
        }
    },
    ["intermediatePaths"] = new[] { restartTemporaryPath },
    ["pendingProcessStarts"] = Array.Empty<object>(),
    ["recoveryMessage"] = null
};
await File.WriteAllTextAsync(recordPath, JsonSerializer.Serialize(pendingRecoveryRecord));
abandonedWorker.Dispose(); // Leave the child running, as if its original host exited.
using var restartedSupervisor = new WorkerSupervisor(tempRoot, pwshPath, workerPath);
var restartRecovery = await restartedSupervisor.RecoverExistingRunAsync();
if (!restartRecovery.HadExistingRun || restartRecovery.RecoveryRequired || File.Exists(restartTemporaryPath))
{
    Console.Error.WriteLine($"Restart recovery failed: required={restartRecovery.RecoveryRequired}, message={restartRecovery.Message}");
    return 1;
}
using (var recoveredRecord = JsonDocument.Parse(await File.ReadAllTextAsync(recordPath)))
{
    if (recoveredRecord.RootElement.GetProperty("status").GetString() != "completed" ||
        !recoveredRecord.RootElement.GetProperty("recoveryMessage").GetString()!.Contains("host restart", StringComparison.Ordinal))
    {
        Console.Error.WriteLine("Restart recovery did not persist a completed recovery record.");
        return 1;
    }
}

var ambiguousRunId = Guid.NewGuid().ToString("D");
var ambiguousRecord = new Dictionary<string, object?>(pendingRecoveryRecord, StringComparer.Ordinal)
{
    ["runId"] = ambiguousRunId,
    ["status"] = "running",
    ["intermediatePaths"] = Array.Empty<string>(),
    ["processes"] = Array.Empty<object>(),
    ["pendingProcessStarts"] = new[]
    {
        new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["processToken"] = Guid.NewGuid().ToString("D"),
            ["executablePath"] = "/usr/bin/ffmpeg",
            ["arguments"] = new[] { "-version" },
            ["parentProcessId"] = Environment.ProcessId,
            ["parentStartedAtUtc"] = DateTimeOffset.UtcNow
        }
    }
};
await File.WriteAllTextAsync(recordPath, JsonSerializer.Serialize(ambiguousRecord));
var ambiguousRecovery = await restartedSupervisor.RecoverExistingRunAsync();
if (!ambiguousRecovery.RecoveryRequired)
{
    Console.Error.WriteLine("An unacknowledged process start was not held for recovery.");
    return 1;
}
var newWorkBlocked = false;
try
{
    await restartedSupervisor.RunAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
    {
        ["schemaVersion"] = 1,
        ["id"] = Guid.NewGuid().ToString("D"),
        ["cmd"] = "capabilities"
    });
}
catch (InvalidOperationException exception) when (exception.Message.Contains("RECOVERY_REQUIRED", StringComparison.Ordinal))
{
    newWorkBlocked = true;
}
if (!newWorkBlocked)
{
    Console.Error.WriteLine("New worker work was not blocked by an unresolved recovery record.");
    return 1;
}

Console.WriteLine("Worker protocol, job-conflict exit 3, incomplete-stream handling, RECOVERY_REQUIRED exit 4, in-host and restart recovery, TERM/KILL, cleanup, and fail-closed suppression passed.");
return 0;

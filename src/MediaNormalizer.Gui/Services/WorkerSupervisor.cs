using System.Collections.Concurrent;
using System.Diagnostics.CodeAnalysis;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MediaNormalizer.Gui.Services;

/// <summary>
/// Owns the worker process, the persistent recovery guard, and process-registration ACKs.
/// The class has no Avalonia dependency so its lifecycle can be exercised by a console harness.
/// </summary>
public sealed class WorkerSupervisor : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };
    private static readonly JsonSerializerOptions WorkerJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly string _pwshPath;
    private readonly string _workerScriptPath;
    private readonly string _storageRoot;
    private readonly string _runDirectory;
    private readonly string _recordPath;
    private readonly Action<JsonElement>? _eventHandler;
    private readonly SemaphoreSlim _recordGate = new(1, 1);
    private readonly SemaphoreSlim _stdinGate = new(1, 1);
    private readonly ConcurrentDictionary<string, ProcessRegistration> _registrations = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, ProcessIdentity> _knownProcesses = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, PendingProcessStart> _pendingStarts = new(StringComparer.Ordinal);
    private Process? _worker;
    private ProcessIdentity? _workerIdentity;
    private StreamWriter? _workerInput;
    private RecoveryRunRecord? _record;
    private CancellationTokenSource? _monitorCancellation;
    private Task? _monitorTask;
    private string? _monitorFailure;
    private string? _runId;
    private string? _requestId;
    private bool _sawRunDone;
    private bool _sawCommandResponse;
    private bool _workerReportedRecoveryRequired;
    private string? _workerRecoveryMessage;

    public WorkerSupervisor(
        string storageRoot,
        string pwshPath,
        string workerScriptPath,
        Action<JsonElement>? eventHandler = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(storageRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(pwshPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(workerScriptPath);
        _storageRoot = Path.GetFullPath(storageRoot);
        _runDirectory = Path.Combine(_storageRoot, "run");
        if (IsInsideAppContents(_runDirectory))
        {
            throw new ArgumentException("Mutable run state cannot be stored under .app/Contents.", nameof(storageRoot));
        }
        _recordPath = Path.Combine(_runDirectory, "active-run.json");
        _pwshPath = Path.GetFullPath(pwshPath);
        _workerScriptPath = Path.GetFullPath(workerScriptPath);
        _eventHandler = eventHandler;
    }

    /// <summary>Acquires the host-only GUI instance lock. The returned handle must live for the host lifetime.</summary>
    public static FileStream AcquireGuiInstanceLock(string storageRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(storageRoot);
        var runDirectory = Path.Combine(Path.GetFullPath(storageRoot), "run");
        if (IsInsideAppContents(runDirectory))
        {
            throw new ArgumentException("Mutable run state cannot be stored under .app/Contents.", nameof(storageRoot));
        }
        Directory.CreateDirectory(runDirectory);
        var path = Path.Combine(runDirectory, "gui-instance.lock");
        try
        {
            return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException exception)
        {
            throw new InvalidOperationException("GUI_ALREADY_RUNNING", exception);
        }
    }

    /// <summary>
    /// Recovers an unresolved GUI run before the host enables new work. An invalid,
    /// CLI-owned, or ambiguous record remains blocked for explicit diagnosis.
    /// </summary>
    public async Task<WorkerRecoveryResult> RecoverExistingRunAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_runDirectory);
        using var recoveryGuard = AcquireRecoveryGuard();
        if (!File.Exists(_recordPath))
        {
            return new WorkerRecoveryResult(false, false, null, null);
        }

        RecoveryRunRecord recoveredRecord;
        try
        {
            recoveredRecord = ReadRecoveryRecord(_recordPath);
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException or KeyNotFoundException or InvalidOperationException or FormatException or OverflowException)
        {
            return new WorkerRecoveryResult(true, true, null, $"RECOVERY_REQUIRED: existing run record is invalid: {exception.Message}");
        }

        if (recoveredRecord.Entrypoint == "cli")
        {
            return recoveredRecord.Status == "completed"
                ? new WorkerRecoveryResult(false, false, recoveredRecord.RunId, null)
                : new WorkerRecoveryResult(true, true, recoveredRecord.RunId, "RECOVERY_REQUIRED: unresolved CLI run requires CLI diagnosis.");
        }
        if (recoveredRecord.Status == "completed")
        {
            return new WorkerRecoveryResult(false, false, recoveredRecord.RunId, null);
        }

        _record = recoveredRecord;
        _runId = recoveredRecord.RunId;
        _knownProcesses.Clear();
        _registrations.Clear();
        _pendingStarts.Clear();
        _workerIdentity = null;
        foreach (var identity in recoveredRecord.Processes)
        {
            _knownProcesses[identity.IdentityKey] = identity;
            if (identity.ProcessToken is not null)
            {
                _registrations[identity.ProcessToken] = new ProcessRegistration(identity.ProcessToken, identity, false);
            }
        }
        foreach (var pendingStart in recoveredRecord.PendingProcessStarts)
        {
            _pendingStarts[pendingStart.ProcessToken] = pendingStart;
        }

        if (recoveredRecord.WorkerProcessId is int workerProcessId && recoveredRecord.WorkerStartedAtUtc is DateTimeOffset workerStartedAtUtc)
        {
            _workerIdentity = new ProcessIdentity
            {
                ProcessId = workerProcessId,
                ParentProcessId = recoveredRecord.OwnerProcessId,
                StartedAtUtc = workerStartedAtUtc,
                ProcessToken = null,
                ExecutablePath = _pwshPath
            };
            if (!recoveredRecord.Processes.Any(item => item.IdentityKey == _workerIdentity.IdentityKey))
            {
                _knownProcesses[_workerIdentity.IdentityKey] = _workerIdentity;
            }
        }

        if (!_pendingStarts.IsEmpty)
        {
            await SetRecoveryRequiredAsync("A process start was recorded without a matching started acknowledgement; the child identity cannot be proven.", CancellationToken.None).ConfigureAwait(false);
            return new WorkerRecoveryResult(true, true, _runId, _record.RecoveryMessage);
        }

        await SetStatusAsync("recovering", cancellationToken).ConfigureAwait(false);
        if (!await RecoverKnownProcessesAsync(cancellationToken).ConfigureAwait(false))
        {
            await SetRecoveryRequiredAsync(_record.RecoveryMessage, CancellationToken.None).ConfigureAwait(false);
            return new WorkerRecoveryResult(true, true, _runId, _record.RecoveryMessage);
        }
        if (!TryAcquireJobLock(out var jobLock) || jobLock is null)
        {
            await SetRecoveryRequiredAsync("The normalization job lock is still held after process recovery.", CancellationToken.None).ConfigureAwait(false);
            return new WorkerRecoveryResult(true, true, _runId, _record.RecoveryMessage);
        }

        using (jobLock)
        {
            if (!CleanupIntermediateFiles())
            {
                await SetRecoveryRequiredAsync("One or more registered intermediate files could not be safely removed.", CancellationToken.None).ConfigureAwait(false);
                return new WorkerRecoveryResult(true, true, _runId, _record.RecoveryMessage);
            }
            _record.Status = "completed";
            _record.ResultCode = 1;
            _record.RecoveryMessage = "Recovered after host restart; tracked processes stopped and registered temporary files cleaned.";
            _record.UpdatedAtUtc = DateTimeOffset.UtcNow;
            await PersistRecordAsync(CancellationToken.None).ConfigureAwait(false);
        }

        return new WorkerRecoveryResult(true, false, _runId, _record.RecoveryMessage);
    }

    public async Task<WorkerSupervisorResult> RunAsync(
        IReadOnlyDictionary<string, object?> command,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(command);
        if (_worker is not null)
        {
            throw new InvalidOperationException("A worker run is already active in this supervisor.");
        }

        Directory.CreateDirectory(_runDirectory);
        using var recoveryGuard = AcquireRecoveryGuard();
        EnsureNoUnresolvedRun();
        _registrations.Clear();
        _knownProcesses.Clear();
        _pendingStarts.Clear();
        _workerIdentity = null;

        var commandCopy = new Dictionary<string, object?>(command, StringComparer.Ordinal);
        _requestId = commandCopy.TryGetValue("id", out var id) && id is string idText && Guid.TryParse(idText, out _)
            ? idText
            : Guid.NewGuid().ToString("D");
        commandCopy["schemaVersion"] = 1;
        commandCopy["id"] = _requestId;
        _runId = commandCopy.TryGetValue("runId", out var runId) && runId is string runIdText && Guid.TryParse(runIdText, out _)
            ? runIdText
            : Guid.NewGuid().ToString("D");
        _sawRunDone = false;
        _sawCommandResponse = false;
        _workerReportedRecoveryRequired = false;
        _workerRecoveryMessage = null;
        if (string.Equals(Convert.ToString(commandCopy.GetValueOrDefault("cmd"), CultureInfo.InvariantCulture), "normalize", StringComparison.Ordinal))
        {
            commandCopy["runId"] = _runId;
        }

        _record = new RecoveryRunRecord
        {
            SchemaVersion = 2,
            RunId = _runId,
            Entrypoint = "gui",
            Status = "running",
            OwnerProcessId = Environment.ProcessId,
            StartedAtUtc = DateTimeOffset.UtcNow,
            UpdatedAtUtc = DateTimeOffset.UtcNow,
            ResultCode = null,
            HostStartedAtUtc = GetProcessStartTime(Environment.ProcessId),
            Processes = [],
            IntermediatePaths = [],
            PendingProcessStarts = []
        };
        await PersistRecordAsync(cancellationToken).ConfigureAwait(false);

        var startInfo = new ProcessStartInfo
        {
            FileName = _pwshPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(_workerScriptPath);
        startInfo.ArgumentList.Add("-StorageRoot");
        startInfo.ArgumentList.Add(_storageRoot);
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        _worker = process;
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("The PowerShell worker did not start.");
            }
            _workerInput = process.StandardInput;
            _record.WorkerProcessId = process.Id;
            _record.WorkerStartedAtUtc = GetProcessStartTime(process.Id);
            _workerIdentity = new ProcessIdentity
            {
                ProcessId = process.Id,
                ParentProcessId = Environment.ProcessId,
                StartedAtUtc = _record.WorkerStartedAtUtc.Value,
                ProcessToken = null,
                ExecutablePath = _pwshPath
            };
            _knownProcesses[_workerIdentity.IdentityKey] = _workerIdentity;
            _record.Processes = _knownProcesses.Values.OrderBy(static item => item.ProcessId).ToList();
            await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
            await WriteCommandAsync(commandCopy, cancellationToken).ConfigureAwait(false);

            var stderrTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var cancellationRegistration = cancellationToken.Register(() => _ = TrySendCancelAsync());
            var streamEndedCleanly = await ReadWorkerEventsAsync(process, CancellationToken.None).ConfigureAwait(false);
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            var stderr = await stderrTask.ConfigureAwait(false);
            StopMonitor();
            await CaptureProcessTreeAsync(CancellationToken.None).ConfigureAwait(false);

            var exitCode = process.ExitCode;
            var commandName = Convert.ToString(commandCopy.GetValueOrDefault("cmd"), CultureInfo.InvariantCulture);
            var normalized = string.Equals(commandName, "normalize", StringComparison.Ordinal);
            var expectedTerminalEvent = commandName switch
            {
                "normalize" => _sawRunDone,
                "capabilities" or "scan" => _sawCommandResponse,
                _ => true
            };
            var cleanJobConflict = normalized && exitCode == 3 && _registrations.IsEmpty && _pendingStarts.IsEmpty &&
                _record.IntermediatePaths.Count == 0;
            var resultExitCode = !expectedTerminalEvent && exitCode == 0 ? 1 : exitCode;
            var normalExit = streamEndedCleanly && (expectedTerminalEvent || cleanJobConflict) && _monitorFailure is null &&
                (exitCode == 0 || cleanJobConflict);
            var needsRecovery = !normalExit || HasLiveRegisteredProcess();

            if (needsRecovery)
            {
                await SetStatusAsync("recovering", cancellationToken).ConfigureAwait(false);
                if (_monitorFailure is not null)
                {
                    await SetRecoveryRequiredAsync($"Process-tree monitoring failed: {_monitorFailure}", CancellationToken.None).ConfigureAwait(false);
                    return new WorkerSupervisorResult(_runId, 4, true, stderr);
                }
                var recovered = await RecoverKnownProcessesAsync(CancellationToken.None).ConfigureAwait(false);
                if (!recovered || !_pendingStarts.IsEmpty)
                {
                    await SetRecoveryRequiredAsync(stderr, CancellationToken.None).ConfigureAwait(false);
                    return new WorkerSupervisorResult(_runId, 4, true, stderr);
                }
                if (!TryAcquireJobLock(out var jobLock) || jobLock is null)
                {
                    await SetRecoveryRequiredAsync("The normalization job lock remained held after process recovery.", CancellationToken.None).ConfigureAwait(false);
                    return new WorkerSupervisorResult(_runId, 4, true, stderr);
                }
                using (jobLock)
                {
                    if (!CleanupIntermediateFiles())
                    {
                        await SetRecoveryRequiredAsync("One or more registered intermediate files could not be safely removed.", CancellationToken.None).ConfigureAwait(false);
                        return new WorkerSupervisorResult(_runId, 4, true, stderr);
                    }
                    if (_workerReportedRecoveryRequired)
                    {
                        await SetRecoveryRequiredAsync(_workerRecoveryMessage, CancellationToken.None).ConfigureAwait(false);
                        return new WorkerSupervisorResult(_runId, 4, true, stderr);
                    }
                    await PersistRecordAsync(CancellationToken.None).ConfigureAwait(false);
                }
            }
            else if (!CleanupIntermediateFiles())
            {
                await SetRecoveryRequiredAsync("One or more registered intermediate files could not be safely removed.", CancellationToken.None).ConfigureAwait(false);
                return new WorkerSupervisorResult(_runId, 4, true, stderr);
            }

            _record.ResultCode = resultExitCode;
            _record.Status = "completed";
            _record.RecoveryMessage = needsRecovery ? "Registered process tree stopped and job lock reacquired." : null;
            _record.UpdatedAtUtc = DateTimeOffset.UtcNow;
            await PersistRecordAsync(CancellationToken.None).ConfigureAwait(false);
            return new WorkerSupervisorResult(_runId, resultExitCode, false, stderr);
        }
        catch (Exception exception)
        {
            StopMonitor();
            if (!process.HasExited)
            {
                try
                {
                    using var waitTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                    await process.WaitForExitAsync(waitTimeout.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    // The durable recovery record below blocks subsequent work if the worker will not stop.
                }
            }
            if (process.HasExited && _monitorFailure is null)
            {
                await CaptureProcessTreeAsync(CancellationToken.None).ConfigureAwait(false);
                await SetStatusAsync("recovering", CancellationToken.None).ConfigureAwait(false);
                var recovered = await RecoverKnownProcessesAsync(CancellationToken.None).ConfigureAwait(false);
                if (recovered && _pendingStarts.IsEmpty && TryAcquireJobLock(out var jobLock) && jobLock is not null)
                {
                    using (jobLock)
                    {
                        if (CleanupIntermediateFiles())
                        {
                            _record!.Status = "completed";
                            _record.ResultCode = 1;
                            _record.RecoveryMessage = "Worker failed; registered process tree stopped.";
                            _record.UpdatedAtUtc = DateTimeOffset.UtcNow;
                            await PersistRecordAsync(CancellationToken.None).ConfigureAwait(false);
                            return new WorkerSupervisorResult(_runId!, 1, false, exception.Message);
                        }
                        await SetRecoveryRequiredAsync("One or more registered intermediate files could not be safely removed.", CancellationToken.None).ConfigureAwait(false);
                        return new WorkerSupervisorResult(_runId!, 4, true, exception.Message);
                    }
                }
            }
            await SetRecoveryRequiredAsync(exception.Message, CancellationToken.None).ConfigureAwait(false);
            return new WorkerSupervisorResult(_runId!, 4, true, exception.Message);
        }
        finally
        {
            StopMonitor();
            _workerInput?.Dispose();
            _workerInput = null;
            process.Dispose();
            _worker = null;
            _runId = null;
            _requestId = null;
            _sawRunDone = false;
            _sawCommandResponse = false;
            _workerReportedRecoveryRequired = false;
            _workerRecoveryMessage = null;
            _registrations.Clear();
            _pendingStarts.Clear();
            _knownProcesses.Clear();
            _workerIdentity = null;
            _monitorFailure = null;
        }
    }

    private FileStream AcquireRecoveryGuard()
    {
        var path = Path.Combine(_runDirectory, "recovery-guard.lock");
        try
        {
            return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException exception)
        {
            throw new InvalidOperationException("JOB_ALREADY_RUNNING: another host owns the recovery guard.", exception);
        }
    }

    private void EnsureNoUnresolvedRun()
    {
        if (!File.Exists(_recordPath))
        {
            return;
        }

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(_recordPath));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("schemaVersion", out var schemaVersion) || schemaVersion.ValueKind != JsonValueKind.Number ||
                !root.TryGetProperty("runId", out var runId) || !Guid.TryParse(runId.GetString(), out _) ||
                !root.TryGetProperty("entrypoint", out var entrypoint) || entrypoint.GetString() is not ("cli" or "gui") ||
                !root.TryGetProperty("status", out var status) || status.GetString() is not ("running" or "recovering" or "completed" or "recovery-required"))
            {
                throw new InvalidOperationException("RECOVERY_REQUIRED: the existing run record is invalid.");
            }
            var supportedVersion = (entrypoint.GetString() == "cli" && schemaVersion.GetInt32() == 1) ||
                (entrypoint.GetString() == "gui" && schemaVersion.GetInt32() == 2);
            if (entrypoint.GetString() == "gui" &&
                (!root.TryGetProperty("hostStartedAtUtc", out _) || !root.TryGetProperty("workerProcessId", out _) ||
                 !root.TryGetProperty("workerStartedAtUtc", out _) || !root.TryGetProperty("processes", out var processes) || processes.ValueKind != JsonValueKind.Array ||
                 !root.TryGetProperty("intermediatePaths", out var intermediatePaths) || intermediatePaths.ValueKind != JsonValueKind.Array ||
                 !root.TryGetProperty("pendingProcessStarts", out var pendingStarts) || pendingStarts.ValueKind != JsonValueKind.Array ||
                 !root.TryGetProperty("recoveryMessage", out _)))
            {
                throw new InvalidOperationException("RECOVERY_REQUIRED: the existing GUI run record is invalid.");
            }
            if (!supportedVersion || !string.Equals(status.GetString(), "completed", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("RECOVERY_REQUIRED: an unresolved run record exists.");
            }
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException("RECOVERY_REQUIRED: the existing run record is invalid.", exception);
        }
    }

    private static RecoveryRunRecord ReadRecoveryRecord(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        ValidateObjectProperties(root, "schemaVersion", "runId", "entrypoint", "status", "ownerProcessId", "startedAtUtc", "updatedAtUtc", "resultCode", "hostStartedAtUtc", "workerProcessId", "workerStartedAtUtc", "processes", "intermediatePaths", "pendingProcessStarts", "recoveryMessage");
        if (root.GetProperty("entrypoint").GetString() == "cli")
        {
            RequireProperties(root, "schemaVersion", "runId", "entrypoint", "status", "ownerProcessId", "startedAtUtc", "updatedAtUtc", "resultCode");
            var cliStatus = root.GetProperty("status").GetString();
            if (root.GetProperty("schemaVersion").GetInt32() != 1 || cliStatus is not ("running" or "recovering" or "completed" or "recovery-required") ||
                !Guid.TryParse(root.GetProperty("runId").GetString(), out _) || root.GetProperty("ownerProcessId").GetInt32() < 1 ||
                !DateTimeOffset.TryParse(root.GetProperty("startedAtUtc").GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _) ||
                !DateTimeOffset.TryParse(root.GetProperty("updatedAtUtc").GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _) ||
                root.GetProperty("resultCode").ValueKind is not (JsonValueKind.Number or JsonValueKind.Null))
            {
                throw new InvalidDataException("CLI run record does not match the supported schema.");
            }
            return new RecoveryRunRecord { SchemaVersion = 1, Entrypoint = "cli", RunId = root.GetProperty("runId").GetString()!, Status = cliStatus! };
        }
        if (root.GetProperty("schemaVersion").GetInt32() != 2 || root.GetProperty("entrypoint").GetString() != "gui")
        {
            throw new InvalidDataException("GUI run record does not match schema version 2.");
        }

        RequireProperties(root, "schemaVersion", "runId", "entrypoint", "status", "ownerProcessId", "startedAtUtc", "updatedAtUtc", "resultCode", "hostStartedAtUtc", "workerProcessId", "workerStartedAtUtc", "processes", "intermediatePaths", "pendingProcessStarts", "recoveryMessage");
        var record = JsonSerializer.Deserialize<RecoveryRunRecord>(root.GetRawText(), JsonOptions)
            ?? throw new InvalidDataException("GUI run record is empty.");
        if (!Guid.TryParse(record.RunId, out _) || record.OwnerProcessId < 1 ||
            record.Status is not ("running" or "recovering" or "completed" or "recovery-required") ||
            record.StartedAtUtc == default || record.UpdatedAtUtc == default || record.HostStartedAtUtc == default ||
            (record.WorkerProcessId is null) != (record.WorkerStartedAtUtc is null) ||
            record.WorkerProcessId is int workerPid && workerPid < 1 ||
            record.ResultCode is < 0 || record.Processes is null || record.IntermediatePaths is null || record.PendingProcessStarts is null)
        {
            throw new InvalidDataException("GUI run record contains invalid required fields.");
        }

        var processKeys = new HashSet<string>(StringComparer.Ordinal);
        var processTokens = new HashSet<string>(StringComparer.Ordinal);
        var processArray = root.GetProperty("processes");
        if (processArray.ValueKind != JsonValueKind.Array || root.GetProperty("intermediatePaths").ValueKind != JsonValueKind.Array ||
            root.GetProperty("pendingProcessStarts").ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("GUI run record arrays are invalid.");
        }
        foreach (var processElement in processArray.EnumerateArray())
        {
            ValidateObjectProperties(processElement, "processId", "parentProcessId", "startedAtUtc", "processToken", "executablePath");
            RequireProperties(processElement, "processId", "parentProcessId", "startedAtUtc");
        }
        foreach (var process in record.Processes)
        {
            if (process.ProcessId < 1 || process.ParentProcessId < 1 || process.StartedAtUtc == default ||
                process.ProcessToken is not null && !Guid.TryParse(process.ProcessToken, out _) ||
                process.ProcessToken is not null && !processTokens.Add(process.ProcessToken) ||
                !processKeys.Add(process.IdentityKey))
            {
                throw new InvalidDataException("GUI run record contains an invalid or duplicate process identity.");
            }
        }
        foreach (var pathValue in record.IntermediatePaths)
        {
            if (string.IsNullOrWhiteSpace(pathValue))
            {
                throw new InvalidDataException("GUI run record contains an empty intermediate path.");
            }
        }
        var pendingTokens = new HashSet<string>(StringComparer.Ordinal);
        foreach (var pendingElement in root.GetProperty("pendingProcessStarts").EnumerateArray())
        {
            ValidateObjectProperties(pendingElement, "processToken", "executablePath", "arguments", "parentProcessId", "parentStartedAtUtc");
            RequireProperties(pendingElement, "processToken", "executablePath", "arguments", "parentProcessId", "parentStartedAtUtc");
            if (pendingElement.GetProperty("arguments").ValueKind != JsonValueKind.Array)
            {
                throw new InvalidDataException("Pending process arguments must be an array.");
            }
        }
        foreach (var pathElement in root.GetProperty("intermediatePaths").EnumerateArray())
        {
            if (pathElement.ValueKind != JsonValueKind.String)
            {
                throw new InvalidDataException("Intermediate paths must be strings.");
            }
        }
        foreach (var pending in record.PendingProcessStarts)
        {
            if (!Guid.TryParse(pending.ProcessToken, out _) || !pendingTokens.Add(pending.ProcessToken) ||
                string.IsNullOrWhiteSpace(pending.ExecutablePath) || pending.ParentProcessId < 1 || pending.ParentStartedAtUtc == default ||
                pending.Arguments is null || pending.Arguments.Any(static argument => argument is null))
            {
                throw new InvalidDataException("GUI run record contains an invalid pending process start.");
            }
        }
        return record;
    }

    private static void ValidateObjectProperties(JsonElement value, params string[] allowedProperties)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Run record must be a JSON object.");
        }
        var allowed = new HashSet<string>(allowedProperties, StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!allowed.Contains(property.Name))
            {
                throw new InvalidDataException($"Run record contains an unsupported property: {property.Name}.");
            }
        }
    }

    private static void RequireProperties(JsonElement value, params string[] requiredProperties)
    {
        foreach (var property in requiredProperties)
        {
            if (!value.TryGetProperty(property, out _))
            {
                throw new InvalidDataException($"Run record is missing a required property: {property}.");
            }
        }
    }

    private async Task<bool> ReadWorkerEventsAsync(Process process, CancellationToken cancellationToken)
    {
        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null)
            {
                return true;
            }
            if (line.Length > 1_048_576)
            {
                throw new InvalidDataException("RECOVERY_REQUIRED: worker event exceeds the maximum NDJSON line length.");
            }

            using var document = JsonDocument.Parse(line);
            var message = document.RootElement;
            ValidateWorkerEvent(message);
            var type = message.GetProperty("type").GetString()!;
            switch (type)
            {
                case "process-starting":
                    await RegisterProcessStartIntentAsync(message, cancellationToken).ConfigureAwait(false);
                    break;
                case "process-started":
                    await RegisterProcessAsync(message, cancellationToken).ConfigureAwait(false);
                    break;
                case "process-exited":
                    await MarkProcessExitedAsync(message, cancellationToken).ConfigureAwait(false);
                    break;
                case "temporary-output":
                    await RegisterTemporaryOutputAsync(message, cancellationToken).ConfigureAwait(false);
                    break;
                case "run-done":
                    _sawRunDone = true;
                    break;
                case "capabilities-result":
                case "scan-result":
                    _sawCommandResponse = true;
                    break;
                case "error" when string.Equals(message.GetProperty("code").GetString(), "RECOVERY_REQUIRED", StringComparison.Ordinal):
                    _workerReportedRecoveryRequired = true;
                    _workerRecoveryMessage = message.GetProperty("message").GetString();
                    break;
            }
            _eventHandler?.Invoke(message.Clone());
        }
    }

    private void ValidateWorkerEvent(JsonElement message)
    {
        if (message.ValueKind != JsonValueKind.Object ||
            !message.TryGetProperty("schemaVersion", out var schemaVersion) || schemaVersion.ValueKind != JsonValueKind.Number || !schemaVersion.TryGetInt32(out var version) || version != 1 ||
            !message.TryGetProperty("type", out var typeElement) || typeElement.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker emitted an invalid protocol event.");
        }

        var type = typeElement.GetString();
        if (type is not ("capabilities-result" or "scan-result" or "run-start" or "file-start" or "progress" or "log" or "file-done" or "run-done" or "error" or "process-starting" or "process-started" or "process-exited" or "temporary-output"))
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker emitted an unknown protocol event.");
        }

        var shape = type switch
        {
            "capabilities-result" => (new[] { "schemaVersion", "type", "id", "modes", "audioInputExtensions", "videoInputExtensions", "audioOutputFormats" }, new[] { "schemaVersion", "type", "id", "modes", "audioInputExtensions", "videoInputExtensions", "audioOutputFormats" }),
            "scan-result" => (new[] { "schemaVersion", "type", "id", "files" }, new[] { "schemaVersion", "type", "id", "files" }),
            "run-start" => (new[] { "schemaVersion", "type", "runId", "mode" }, new[] { "schemaVersion", "type", "runId", "mode" }),
            "file-start" => (new[] { "schemaVersion", "type", "runId", "fileIndex", "total", "inputPath" }, new[] { "schemaVersion", "type", "runId", "fileIndex", "total", "inputPath" }),
            "progress" => (new[] { "schemaVersion", "type", "runId", "percent", "phase", "eta", "inputPath" }, new[] { "schemaVersion", "type", "runId", "percent", "phase", "eta", "inputPath" }),
            "log" => (new[] { "schemaVersion", "type", "runId", "level", "message" }, new[] { "schemaVersion", "type", "runId", "level", "message" }),
            "file-done" => (new[] { "schemaVersion", "type", "runId", "inputPath", "outputPath", "status", "measurements", "message" }, new[] { "schemaVersion", "type", "runId", "inputPath", "outputPath", "status", "measurements", "message" }),
            "run-done" => (new[] { "schemaVersion", "type", "runId", "success", "analyzed", "fail", "skipped", "cancelled", "reportPath", "reportSucceeded" }, new[] { "schemaVersion", "type", "runId", "success", "analyzed", "fail", "skipped", "cancelled", "reportPath", "reportSucceeded" }),
            "error" => (new[] { "schemaVersion", "type", "code", "message" }, new[] { "schemaVersion", "type", "runId", "inputPath", "code", "message" }),
            "process-starting" => (new[] { "schemaVersion", "type", "runId", "processToken", "executablePath", "arguments", "parentProcessId", "parentStartedAtUtc" }, new[] { "schemaVersion", "type", "runId", "processToken", "executablePath", "arguments", "parentProcessId", "parentStartedAtUtc" }),
            "process-started" => (new[] { "schemaVersion", "type", "runId", "processToken", "processId", "processStartedAtUtc", "executablePath", "parentProcessId", "parentStartedAtUtc" }, new[] { "schemaVersion", "type", "runId", "processToken", "processId", "processStartedAtUtc", "executablePath", "parentProcessId", "parentStartedAtUtc" }),
            "process-exited" => (new[] { "schemaVersion", "type", "runId", "processToken", "processId", "processStartedAtUtc", "exitCode" }, new[] { "schemaVersion", "type", "runId", "processToken", "processId", "processStartedAtUtc", "exitCode" }),
            "temporary-output" => (new[] { "schemaVersion", "type", "runId", "inputPath", "temporaryPath", "finalPath", "role" }, new[] { "schemaVersion", "type", "runId", "inputPath", "temporaryPath", "finalPath", "role" }),
            _ => throw new InvalidDataException("RECOVERY_REQUIRED: worker event shape is unknown.")
        };
        ValidateEventShape(message, shape.Item1, shape.Item2);

        if (message.TryGetProperty("runId", out var runIdElement) &&
            (runIdElement.ValueKind != JsonValueKind.String || !Guid.TryParse(runIdElement.GetString(), out var eventRunId) || !Guid.TryParse(_runId, out var expectedRunId) || eventRunId != expectedRunId))
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker event runId does not match the active run.");
        }
        if (message.TryGetProperty("id", out var idElement) &&
            (idElement.ValueKind != JsonValueKind.String || !Guid.TryParse(idElement.GetString(), out var eventId) || !Guid.TryParse(_requestId, out var expectedId) || eventId != expectedId))
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker response id does not match the request.");
        }

        switch (type)
        {
            case "capabilities-result":
                RequireGuid(message, "id");
                ValidateStringArray(message, "modes", ["audio", "video", "both"]);
                ValidateStringArray(message, "audioInputExtensions");
                ValidateStringArray(message, "videoInputExtensions");
                ValidateStringArray(message, "audioOutputFormats", ["mp3", "m4a", "aac", "flac", "wav", "opus", "ogg"]);
                break;
            case "scan-result":
                RequireGuid(message, "id");
                var files = RequireArray(message, "files");
                foreach (var file in files.EnumerateArray())
                {
                    ValidateEventShape(file, ["path", "extension", "audioEligible", "videoEligible"], ["path", "extension", "audioEligible", "videoEligible"]);
                    RequireEventString(file, "path", nonEmpty: true);
                    RequireEventString(file, "extension");
                    RequireBoolean(file, "audioEligible");
                    RequireBoolean(file, "videoEligible");
                }
                break;
            case "run-start":
                RequireEventEnum(message, "mode", "audio", "video", "both");
                break;
            case "file-start":
                RequireEventInt(message, "fileIndex", 1);
                RequireEventInt(message, "total", 1);
                RequireEventString(message, "inputPath", nonEmpty: true);
                break;
            case "progress":
                RequireEventNumber(message, "percent", 0, 100);
                RequireEventString(message, "phase", nonEmpty: true);
                RequireNumberOrNull(message, "eta", 0, double.MaxValue);
                RequireStringOrNull(message, "inputPath");
                break;
            case "log":
                RequireEventEnum(message, "level", "debug", "info", "warning", "error");
                RequireEventString(message, "message");
                break;
            case "file-done":
                RequireEventString(message, "inputPath", nonEmpty: true);
                RequireStringOrNull(message, "outputPath");
                RequireEventEnum(message, "status", "normalized", "analyzed", "skipped", "failed", "cancelled");
                RequireObjectOrNull(message, "measurements");
                RequireStringOrNull(message, "message");
                break;
            case "run-done":
                RequireEventInt(message, "success", 0);
                RequireEventInt(message, "analyzed", 0);
                RequireEventInt(message, "fail", 0);
                RequireEventInt(message, "skipped", 0);
                RequireEventInt(message, "cancelled", 0);
                RequireStringOrNull(message, "reportPath");
                RequireBooleanOrNull(message, "reportSucceeded");
                break;
            case "error":
                if (message.TryGetProperty("inputPath", out _)) RequireEventString(message, "inputPath");
                RequireEventString(message, "code", nonEmpty: true);
                RequireEventString(message, "message", nonEmpty: true);
                break;
            case "process-starting":
                RequireGuid(message, "processToken");
                RequireEventString(message, "executablePath", nonEmpty: true);
                ValidateStringArray(message, "arguments");
                RequireEventInt(message, "parentProcessId", 1);
                RequireDateTime(message, "parentStartedAtUtc");
                break;
            case "process-started":
                RequireGuid(message, "processToken");
                RequireEventInt(message, "processId", 1);
                RequireDateTime(message, "processStartedAtUtc");
                RequireEventString(message, "executablePath", nonEmpty: true);
                RequireEventInt(message, "parentProcessId", 1);
                RequireDateTime(message, "parentStartedAtUtc");
                break;
            case "process-exited":
                RequireGuid(message, "processToken");
                RequireEventInt(message, "processId", 1);
                RequireDateTime(message, "processStartedAtUtc");
                RequireEventInt(message, "exitCode", int.MinValue);
                break;
            case "temporary-output":
                RequireEventString(message, "inputPath", nonEmpty: true);
                RequireEventString(message, "temporaryPath", nonEmpty: true);
                RequireEventString(message, "finalPath", nonEmpty: true);
                RequireEventEnum(message, "role", "primary", "speed");
                break;
        }
    }

    private static void ValidateEventShape(JsonElement message, string[] required, string[] allowed)
    {
        if (message.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker event must be an object.");
        }
        var allowedSet = new HashSet<string>(allowed, StringComparer.Ordinal);
        if (message.EnumerateObject().Any(property => !allowedSet.Contains(property.Name)) || required.Any(name => !message.TryGetProperty(name, out _)))
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker event has missing or unsupported fields.");
        }
    }

    private static void RequireEventString(JsonElement value, string name, bool nonEmpty = false)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.String ||
            (nonEmpty && string.IsNullOrWhiteSpace(element.GetString())))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not a valid string.");
        }
    }

    private static void RequireGuid(JsonElement value, string name)
    {
        RequireEventString(value, name, nonEmpty: true);
        if (!Guid.TryParse(value.GetProperty(name).GetString(), out _))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not a UUID.");
        }
    }

    private static void RequireEventInt(JsonElement value, string name, int minimum)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.Number || !element.TryGetInt32(out var number) || number < minimum)
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not a valid integer.");
        }
    }

    private static void RequireEventNumber(JsonElement value, string name, double minimum, double maximum)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.Number ||
            !element.TryGetDouble(out var number) || !double.IsFinite(number) || number < minimum || number > maximum)
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not a valid number.");
        }
    }

    private static void RequireNumberOrNull(JsonElement value, string name, double minimum, double maximum)
    {
        if (!value.TryGetProperty(name, out var element) ||
            (element.ValueKind != JsonValueKind.Null && (element.ValueKind != JsonValueKind.Number || !element.TryGetDouble(out var number) || !double.IsFinite(number) || number < minimum || number > maximum)))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' must be a number or null.");
        }
    }

    private static void RequireBoolean(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not a boolean.");
        }
    }

    private static void RequireBooleanOrNull(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind is not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' must be a boolean or null.");
        }
    }

    private static void RequireStringOrNull(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind is not (JsonValueKind.String or JsonValueKind.Null))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' must be a string or null.");
        }
    }

    private static void RequireObjectOrNull(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind is not (JsonValueKind.Object or JsonValueKind.Null))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' must be an object or null.");
        }
    }

    private static void RequireEventEnum(JsonElement value, string name, params string[] allowedValues)
    {
        RequireEventString(value, name);
        if (!allowedValues.Contains(value.GetProperty(name).GetString(), StringComparer.Ordinal))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not an allowed value.");
        }
    }

    private static JsonElement RequireArray(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not an array.");
        }
        return element;
    }

    private static void ValidateStringArray(JsonElement value, string name, string[]? allowedValues = null)
    {
        foreach (var item in RequireArray(value, name).EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || allowedValues is not null && !allowedValues.Contains(item.GetString(), StringComparer.Ordinal))
            {
                throw new InvalidDataException($"RECOVERY_REQUIRED: worker array '{name}' contains an invalid item.");
            }
        }
    }

    private static void RequireDateTime(JsonElement value, string name)
    {
        RequireEventString(value, name, nonEmpty: true);
        if (!DateTimeOffset.TryParse(value.GetProperty(name).GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _))
        {
            throw new InvalidDataException($"RECOVERY_REQUIRED: worker field '{name}' is not a timestamp.");
        }
    }

    private async Task RegisterProcessStartIntentAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var token = message.GetProperty("processToken").GetString()!;
        var executable = message.GetProperty("executablePath").GetString()!;
        var pending = new PendingProcessStart
        {
            ProcessToken = token,
            ExecutablePath = executable,
            Arguments = message.GetProperty("arguments").EnumerateArray().Select(static item => item.GetString() ?? string.Empty).ToList(),
            ParentProcessId = message.GetProperty("parentProcessId").GetInt32(),
            ParentStartedAtUtc = DateTimeOffset.Parse(message.GetProperty("parentStartedAtUtc").GetString()!, CultureInfo.InvariantCulture)
        };
        _pendingStarts[token] = pending;
        _record!.PendingProcessStarts = _pendingStarts.Values.ToList();
        await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task RegisterProcessAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var token = message.GetProperty("processToken").GetString()!;
        var processId = message.GetProperty("processId").GetInt32();
        var startedAtUtc = DateTimeOffset.Parse(message.GetProperty("processStartedAtUtc").GetString()!, CultureInfo.InvariantCulture);
        var parentProcessId = message.GetProperty("parentProcessId").GetInt32();
        var executablePath = message.GetProperty("executablePath").GetString()!;
        var identity = TryGetProcessIdentity(processId, parentProcessId, token, startedAtUtc, executablePath);
        var accepted = identity is not null;
        if (identity is not null)
        {
            _registrations[token] = new ProcessRegistration(token, identity, false);
            _knownProcesses[identity.IdentityKey] = identity;
            _pendingStarts.TryRemove(token, out _);
            _record!.PendingProcessStarts = _pendingStarts.Values.ToList();
            _record.Processes = _knownProcesses.Values.OrderBy(static item => item.ProcessId).ToList();
            await CaptureProcessTreeAsync(cancellationToken).ConfigureAwait(false);
            await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
            StartMonitorIfNeeded();
        }
        else
        {
            _record!.RecoveryMessage = $"Could not verify process identity before ACK (pid={processId}).";
            await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
        }

        await SendCommandAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = 1,
            ["id"] = Guid.NewGuid().ToString("D"),
            ["cmd"] = "process-registration-ack",
            ["runId"] = _runId,
            ["processToken"] = token,
            ["processId"] = processId,
            ["processStartedAtUtc"] = message.GetProperty("processStartedAtUtc").GetString(),
            ["accepted"] = accepted,
            ["reason"] = accepted ? null : "host could not verify process identity"
        }, cancellationToken).ConfigureAwait(false);

        if (!accepted)
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: host could not verify the child process identity.");
        }
    }

    private async Task RegisterTemporaryOutputAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var temporaryPath = Path.GetFullPath(message.GetProperty("temporaryPath").GetString()!);
        var finalPath = Path.GetFullPath(message.GetProperty("finalPath").GetString()!);
        var role = message.GetProperty("role").GetString();
        var accepted = Guid.TryParse(_runId, out var runId) &&
            !string.Equals(temporaryPath, finalPath, StringComparison.Ordinal) &&
            Path.GetFileName(temporaryPath).Contains(runId.ToString("D"), StringComparison.OrdinalIgnoreCase) &&
            !IsInsideAppContents(temporaryPath) &&
            (role != "primary" || string.Equals(Path.GetDirectoryName(temporaryPath), Path.GetDirectoryName(finalPath), StringComparison.Ordinal));
        if (accepted)
        {
            if (!_record!.IntermediatePaths.Contains(temporaryPath, StringComparer.Ordinal))
            {
                _record.IntermediatePaths.Add(temporaryPath);
                await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
            }
        }

        await SendCommandAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = 1,
            ["id"] = Guid.NewGuid().ToString("D"),
            ["cmd"] = "temporary-file-registration-ack",
            ["runId"] = _runId,
            ["temporaryPath"] = temporaryPath,
            ["accepted"] = accepted,
            ["reason"] = accepted ? null : "host rejected a non-run-scoped temporary path"
        }, cancellationToken).ConfigureAwait(false);

        if (!accepted)
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: host rejected a temporary output path.");
        }
    }

    private static bool IsInsideAppContents(string path)
    {
        var parts = Path.GetFullPath(path).Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index + 1 < parts.Length; index++)
        {
            if (parts[index].EndsWith(".app", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(parts[index + 1], "Contents", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private async Task MarkProcessExitedAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var token = message.GetProperty("processToken").GetString()!;
        if (!_registrations.TryGetValue(token, out var registration))
        {
            throw new InvalidDataException("RECOVERY_REQUIRED: worker reported an unknown process exit.");
        }
        _registrations[token] = registration with { ExitNotified = true };
        await CaptureProcessTreeAsync(cancellationToken).ConfigureAwait(false);
        await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
    }

    private static ProcessIdentity? TryGetProcessIdentity(int processId, int parentProcessId, string? token, DateTimeOffset expectedStart, string? executablePath)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            if (process.HasExited)
            {
                return null;
            }
            var actualStart = new DateTimeOffset(process.StartTime.ToUniversalTime());
            if (actualStart.UtcTicks != expectedStart.UtcTicks)
            {
                return null;
            }
            return new ProcessIdentity
            {
                ProcessId = processId,
                ParentProcessId = parentProcessId,
                StartedAtUtc = actualStart,
                ProcessToken = token,
                ExecutablePath = executablePath
            };
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    private void StartMonitorIfNeeded()
    {
        if (_monitorTask is not null)
        {
            return;
        }
        _monitorCancellation = new CancellationTokenSource();
        _monitorTask = Task.Run(() => MonitorProcessTreesAsync(_monitorCancellation.Token));
    }

    private async Task MonitorProcessTreesAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && _worker is { HasExited: false })
        {
            try
            {
                await CaptureProcessTreeAsync(cancellationToken).ConfigureAwait(false);
                await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception)
            {
                _monitorFailure = exception.Message;
                _record!.RecoveryMessage = $"Process-tree monitoring failed: {exception.Message}";
                try
                {
                    await SetStatusAsync("recovery-required", CancellationToken.None).ConfigureAwait(false);
                }
                catch (IOException)
                {
                    // Keep the last valid durable record if the storage path becomes unavailable.
                }
                return;
            }
            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task CaptureProcessTreeAsync(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux())
        {
            return;
        }
        var roots = _registrations.Values.Select(static item => item.Identity)
            .Concat(_workerIdentity is null ? [] : [_workerIdentity])
            .DistinctBy(static item => item.IdentityKey)
            .ToArray();
        if (roots.Length == 0)
        {
            return;
        }

        var parentMap = await ReadProcessParentsAsync(cancellationToken).ConfigureAwait(false);
        foreach (var root in roots)
        {
            if (!parentMap.ContainsKey(root.ProcessId) || !IdentityMatches(root))
            {
                continue;
            }
            var frontier = new Queue<int>();
            frontier.Enqueue(root.ProcessId);
            while (frontier.TryDequeue(out var parentId))
            {
                foreach (var childId in parentMap.Where(pair => pair.Value == parentId).Select(static pair => pair.Key))
                {
                    frontier.Enqueue(childId);
                    try
                    {
                        using var child = Process.GetProcessById(childId);
                        var childIdentity = new ProcessIdentity
                        {
                            ProcessId = childId,
                            ParentProcessId = parentId,
                            StartedAtUtc = new DateTimeOffset(child.StartTime.ToUniversalTime()),
                            ProcessToken = null,
                            ExecutablePath = null
                        };
                        _knownProcesses[childIdentity.IdentityKey] = childIdentity;
                    }
                    catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
                    {
                        // The child exited between the ps snapshot and identity lookup; a later snapshot will confirm absence.
                    }
                }
            }
        }
        _record!.Processes = _knownProcesses.Values.OrderBy(static item => item.ProcessId).ToList();
    }

    private static async Task<Dictionary<int, int>> ReadProcessParentsAsync(CancellationToken cancellationToken)
    {
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = "/bin/ps",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        process.StartInfo.ArgumentList.Add("-axo");
        process.StartInfo.ArgumentList.Add("pid=,ppid=");
        if (!process.Start())
        {
            throw new InvalidOperationException("Could not start /bin/ps for process recovery.");
        }
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        var output = await stdoutTask.ConfigureAwait(false);
        var error = await stderrTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Could not inspect process tree: {error}");
        }
        var result = new Dictionary<int, int>();
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (fields.Length == 2 && int.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out var pid) &&
                int.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out var parentId))
            {
                result[pid] = parentId;
            }
        }
        return result;
    }

    private bool HasLiveRegisteredProcess() => _knownProcesses.Values.Any(IdentityMatches);

    private bool CleanupIntermediateFiles()
    {
        if (_record is null || !Guid.TryParse(_record.RunId, out var runId))
        {
            return false;
        }
        foreach (var path in _record.IntermediatePaths.ToArray())
        {
            var fullPath = Path.GetFullPath(path);
            if (!string.Equals(path, fullPath, StringComparison.Ordinal) || IsInsideAppContents(fullPath) ||
                !Path.GetFileName(fullPath).Contains(runId.ToString("D"), StringComparison.OrdinalIgnoreCase) || Directory.Exists(fullPath))
            {
                return false;
            }
            if (!File.Exists(fullPath))
            {
                continue;
            }
            try
            {
                if ((File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
                {
                    return false;
                }
                File.Delete(fullPath);
                if (File.Exists(fullPath))
                {
                    return false;
                }
            }
            catch (IOException)
            {
                return false;
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
        }
        _record.IntermediatePaths.Clear();
        return true;
    }

    private async Task<bool> RecoverKnownProcessesAsync(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux())
        {
            if (_knownProcesses.Values.Any(IdentityMatches))
            {
                _record!.RecoveryMessage = "Tracked processes remain alive, but this operating system has no supported process-tree recovery adapter.";
                return false;
            }
            return _pendingStarts.IsEmpty;
        }

        try
        {
            await CaptureProcessTreeAsync(cancellationToken).ConfigureAwait(false);
            var live = _knownProcesses.Values.Where(IdentityMatches).OrderByDescending(GetProcessDepth).ToArray();
            var unverifiedRoots = false;
            foreach (var registration in _registrations.Values.Where(static item => !item.ExitNotified))
            {
                if (!IdentityMatches(registration.Identity))
                {
                    unverifiedRoots = true;
                    _record!.RecoveryMessage = $"Unacknowledged process exit cannot be verified (pid={registration.Identity.ProcessId}).";
                }
            }
            if (unverifiedRoots)
            {
                return false;
            }

            foreach (var identity in live)
            {
                if (!IdentityMatches(identity))
                {
                    continue;
                }
                await SendSignalAsync("TERM", identity, cancellationToken).ConfigureAwait(false);
            }
            await Task.Delay(TimeSpan.FromMilliseconds(600), cancellationToken).ConfigureAwait(false);
            await CaptureProcessTreeAsync(cancellationToken).ConfigureAwait(false);
            var afterTerm = _knownProcesses.Values.Where(IdentityMatches).OrderByDescending(GetProcessDepth).ToArray();
            foreach (var identity in afterTerm)
            {
                if (IdentityMatches(identity))
                {
                    await SendSignalAsync("KILL", identity, cancellationToken).ConfigureAwait(false);
                }
            }
            await Task.Delay(TimeSpan.FromMilliseconds(150), cancellationToken).ConfigureAwait(false);
            await CaptureProcessTreeAsync(cancellationToken).ConfigureAwait(false);
            var remaining = _knownProcesses.Values.Where(IdentityMatches).ToArray();
            if (remaining.Length > 0)
            {
                _record!.RecoveryMessage = "One or more registered process identities remain alive after TERM/KILL.";
                return false;
            }
            return _pendingStarts.IsEmpty;
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _record!.RecoveryMessage = $"Process recovery could not prove all tracked processes stopped: {exception.Message}";
            return false;
        }
    }

    private int GetProcessDepth(ProcessIdentity identity)
    {
        var depth = 0;
        var parentId = identity.ParentProcessId;
        var visited = new HashSet<int>();
        while (parentId > 0 && visited.Add(parentId))
        {
            var parent = _knownProcesses.Values.FirstOrDefault(item => item.ProcessId == parentId);
            if (parent is null)
            {
                break;
            }
            depth++;
            parentId = parent.ParentProcessId;
        }
        return depth;
    }

    private static async Task SendSignalAsync(string signal, ProcessIdentity identity, CancellationToken cancellationToken)
    {
        if (!IdentityMatches(identity))
        {
            return;
        }
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = "/bin/kill",
            UseShellExecute = false,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        process.StartInfo.ArgumentList.Add($"-{signal}");
        process.StartInfo.ArgumentList.Add(identity.ProcessId.ToString(CultureInfo.InvariantCulture));
        if (!process.Start())
        {
            throw new InvalidOperationException("Could not start /bin/kill.");
        }
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            var error = await errorTask.ConfigureAwait(false);
            if (!error.Contains("No such process", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException($"Could not signal pid {identity.ProcessId}: {error}");
            }
        }
    }

    private static bool IdentityMatches(ProcessIdentity identity)
    {
        try
        {
            using var process = Process.GetProcessById(identity.ProcessId);
            if (process.HasExited)
            {
                return false;
            }
            var actualStart = new DateTimeOffset(process.StartTime.ToUniversalTime());
            return actualStart.UtcTicks == identity.StartedAtUtc.UtcTicks;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static DateTimeOffset GetProcessStartTime(int processId)
    {
        using var process = Process.GetProcessById(processId);
        return new DateTimeOffset(process.StartTime.ToUniversalTime());
    }

    private async Task WriteCommandAsync(IDictionary<string, object?> command, CancellationToken cancellationToken)
    {
        await _stdinGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _workerInput!.WriteLineAsync(JsonSerializer.Serialize(command, WorkerJsonOptions).AsMemory(), cancellationToken).ConfigureAwait(false);
            await _workerInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _stdinGate.Release();
        }
    }

    private Task SendCommandAsync(IDictionary<string, object?> command, CancellationToken cancellationToken) => WriteCommandAsync(command, cancellationToken);

    private async Task TrySendCancelAsync()
    {
        if (_workerInput is null || _runId is null || _worker is not { HasExited: false })
        {
            return;
        }
        try
        {
            await SendCommandAsync(new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["schemaVersion"] = 1,
                ["id"] = Guid.NewGuid().ToString("D"),
                ["cmd"] = "cancel",
                ["runId"] = _runId
            }, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException or InvalidOperationException)
        {
            _record!.RecoveryMessage = $"Cancellation command could not be sent: {exception.Message}";
        }
    }

    private void StopMonitor()
    {
        _monitorCancellation?.Cancel();
        try
        {
            _monitorTask?.GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            // Expected when the worker exits.
        }
        _monitorCancellation?.Dispose();
        _monitorCancellation = null;
        _monitorTask = null;
    }

    private bool TryAcquireJobLock([NotNullWhen(true)] out FileStream? jobLock)
    {
        var path = Path.Combine(_runDirectory, "normalization-job.lock");
        try
        {
            jobLock = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return true;
        }
        catch (IOException)
        {
            jobLock = null;
            return false;
        }
    }

    private async Task SetStatusAsync(string status, CancellationToken cancellationToken)
    {
        _record!.Status = status;
        _record.UpdatedAtUtc = DateTimeOffset.UtcNow;
        await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task SetRecoveryRequiredAsync(string? message, CancellationToken cancellationToken)
    {
        _record!.Status = "recovery-required";
        _record.ResultCode = 4;
        _record.RecoveryMessage = string.IsNullOrWhiteSpace(message)
            ? _record.RecoveryMessage ?? "Worker recovery could not be verified."
            : message;
        _record.UpdatedAtUtc = DateTimeOffset.UtcNow;
        await PersistRecordAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task PersistRecordAsync(CancellationToken cancellationToken)
    {
        await _recordGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var temporaryPath = $"{_recordPath}.{Guid.NewGuid():N}.tmp";
        try
        {
            _record!.UpdatedAtUtc = DateTimeOffset.UtcNow;
            var json = JsonSerializer.Serialize(_record, JsonOptions);
            await File.WriteAllTextAsync(temporaryPath, json, new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            File.Move(temporaryPath, _recordPath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
            _recordGate.Release();
        }
    }

    public void Dispose()
    {
        StopMonitor();
        _workerInput?.Dispose();
        _workerInput = null;
        _worker?.Dispose();
        _worker = null;
        _recordGate.Dispose();
        _stdinGate.Dispose();
    }

    private sealed class RecoveryRunRecord
    {
        public int SchemaVersion { get; set; }
        public string RunId { get; set; } = string.Empty;
        public string Entrypoint { get; set; } = string.Empty;
        public string Status { get; set; } = string.Empty;
        public int OwnerProcessId { get; set; }
        public DateTimeOffset StartedAtUtc { get; set; }
        public DateTimeOffset UpdatedAtUtc { get; set; }
        public int? ResultCode { get; set; }
        public DateTimeOffset HostStartedAtUtc { get; set; }
        public int? WorkerProcessId { get; set; }
        public DateTimeOffset? WorkerStartedAtUtc { get; set; }
        public List<ProcessIdentity> Processes { get; set; } = [];
        public List<string> IntermediatePaths { get; set; } = [];
        public List<PendingProcessStart> PendingProcessStarts { get; set; } = [];
        public string? RecoveryMessage { get; set; }
    }

    private sealed class ProcessIdentity
    {
        public int ProcessId { get; set; }
        public int ParentProcessId { get; set; }
        public DateTimeOffset StartedAtUtc { get; set; }
        public string? ProcessToken { get; set; }
        public string? ExecutablePath { get; set; }
        [JsonIgnore]
        public string IdentityKey => $"{ProcessId}:{StartedAtUtc.UtcTicks}";
    }

    private sealed class PendingProcessStart
    {
        public string ProcessToken { get; set; } = string.Empty;
        public string ExecutablePath { get; set; } = string.Empty;
        public List<string> Arguments { get; set; } = [];
        public int ParentProcessId { get; set; }
        public DateTimeOffset ParentStartedAtUtc { get; set; }
    }

    private sealed record ProcessRegistration(string Token, ProcessIdentity Identity, bool ExitNotified);
}

public sealed record WorkerSupervisorResult(string RunId, int ExitCode, bool RecoveryRequired, string StandardError);
public sealed record WorkerRecoveryResult(bool HadExistingRun, bool RecoveryRequired, string? RunId, string? Message);

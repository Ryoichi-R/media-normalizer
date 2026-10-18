using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace MediaNormalizer.Gui.Services;

public sealed class GuiRuntime
{
    public string Resources { get; }
    public string StorageRoot { get; }
    public string LogPath => string.Equals(StorageRoot, Path.GetDirectoryName(SettingsStore.GetDefaultSettingsPath()), StringComparison.Ordinal)
        ? Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), "Library", "Logs", "media-normalizer", "media-normalizer.log")
        : Path.Combine(StorageRoot, "logs", "media-normalizer.log");
    public string PowerShellPath => Path.Combine(Resources, "runtime", "powershell", "pwsh");
    public IReadOnlyDictionary<string, string?> EnvironmentVariables { get; }

    public GuiRuntime(string resources, string storageRoot)
    {
        Resources = Path.GetFullPath(resources);
        StorageRoot = Path.GetFullPath(storageRoot);
        var runtime = Path.Combine(Resources, "runtime");
        EnvironmentVariables = new Dictionary<string, string?>
        {
            ["MEDIA_NORMALIZER_RUNTIME_ROOT"] = runtime,
            ["FFMPEG_PATH"] = Path.Combine(runtime, "ffmpeg", "bin", "ffmpeg"),
            ["FFPROBE_PATH"] = Path.Combine(runtime, "ffmpeg", "bin", "ffprobe"),
            ["MEDIA_NORMALIZER_PYTHON"] = Path.Combine(runtime, "python", "bin", "python3"),
            ["PYTHONHOME"] = Path.Combine(runtime, "python"),
            ["PYTHONPATH"] = null,
            ["PYTHONNOUSERSITE"] = "1",
            ["PYTHONDONTWRITEBYTECODE"] = "1",
            ["PATH"] = Path.Combine(runtime, "ffmpeg", "bin") + ":" + Path.Combine(runtime, "python", "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
        };
    }

    public WorkerSupervisor CreateSupervisor(Action<JsonElement>? handler = null) =>
        new(StorageRoot, PowerShellPath, Path.Combine(Resources, "scripts", "mn-worker.ps1"), handler, EnvironmentVariables);

    public async Task ValidateAsync(CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsMacOS()) { throw new PlatformNotSupportedException("このGUIはmacOS用です。"); }
        using var manifest = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(Resources, "runtime", "dependency-manifest.json"), cancellationToken).ConfigureAwait(false));
        var root = manifest.RootElement;
        if (root.GetProperty("schemaVersion").GetInt32() != 1 || root.GetProperty("runtime").GetString() != "osx-arm64")
            throw new InvalidDataException("同梱ランタイムの形式が不正です。");
        var entries = root.GetProperty("criticalFiles").EnumerateArray().Where(e => e.GetProperty("name").GetString() == "PowerShell").ToArray();
        if (entries.Length != 1 || entries[0].GetProperty("path").GetString() != "powershell/pwsh")
            throw new InvalidDataException("同梱PowerShellの検証情報がありません。");
        await using (var stream = File.OpenRead(PowerShellPath))
        {
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false));
            if (!string.Equals(hash, entries[0].GetProperty("sha256").GetString(), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("同梱PowerShellのSHA-256が一致しません。");
        }
        var info = new ProcessStartInfo(PowerShellPath) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var pair in EnvironmentVariables) { info.Environment[pair.Key] = pair.Value; }
        foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-File", Path.Combine(Resources, "diagnostics", "runtime-check.ps1"), "-RuntimeRoot", Path.Combine(Resources, "runtime"), "-Quiet" }) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new IOException("診断を開始できません。");
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = process.StandardError.ReadToEndAsync(cancellationToken);
        try { await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false); }
        catch { if (!process.HasExited) process.Kill(true); throw; }
        var detail = await output.ConfigureAwait(false) + await error.ConfigureAwait(false);
        if (process.ExitCode != 0) throw new InvalidDataException(detail);
    }
}

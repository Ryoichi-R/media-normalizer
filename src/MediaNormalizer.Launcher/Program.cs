using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace MediaNormalizer.Launcher;

internal static class Program
{
    private const string Product = "Media Normalizer";
    private const int RuntimeCheckFailed = 20;
    private const int GuiChildFailed = 21;
    private const int ActivationUnavailable = 22;
    private const int ActivationInvalid = 23;
    private const int WindowReadyTimeout = 24;
    private const int RunningLockHeld = 25;

    [STAThread]
    private static int Main(string[] args)
    {
        Mutex? mutex = null;
        var mutexTaken = false;
        try
        {
            var root = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
            var script = RequireFile(root, "media-normalizer.ps1");
            var runtimeCheck = RequireFile(root, "runtime-check.ps1");
            var ffmpeg = RequireFile(root, @"runtime\ffmpeg\bin\ffmpeg.exe");
            var ffprobe = RequireFile(root, @"runtime\ffmpeg\bin\ffprobe.exe");
            var python = RequireFile(root, @"runtime\python\python.exe");
            var shell = FindShell();
            var pathHash = StableHash(root);
            var mutexName = $"Local\\MediaNormalizer-App-{pathHash}";
            var pipeName = BuildPipeName(pathHash);

            mutex = new Mutex(false, mutexName);
            var recoveredAbandonedMutex = false;
            try
            {
                mutexTaken = mutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                mutexTaken = true;
                recoveredAbandonedMutex = true;
            }

            if (!mutexTaken)
            {
                if (args.Length > 0)
                {
                    return 2;
                }

                return ActivateExisting(pipeName);
            }

            var environment = new Dictionary<string, string>
            {
                ["MEDIA_NORMALIZER_RUNTIME_ROOT"] = Path.Combine(root, "runtime"),
                ["FFMPEG_PATH"] = ffmpeg,
                ["FFPROBE_PATH"] = ffprobe,
                ["MEDIA_NORMALIZER_PYTHON"] = python
            };

            if (args.Length > 0)
            {
                var checkExit = RunPowerShellAndWait(shell, runtimeCheck, [], root, environment);
                if (checkExit != 0) return checkExit;
                return RunPowerShellAndWait(shell, script, args, root, environment);
            }

            ActivationServer? activationServer = null;
            try
            {
                activationServer = ActivationServer.TryStart(pipeName);

                var checkExit = RunPowerShellAndWait(shell, runtimeCheck, [], root, environment);
                if (checkExit != 0)
                {
                    activationServer?.SetTerminalFailure();
                    ShowError($"同梱ランタイムの確認に失敗しました。終了コード: {checkExit}\n" +
                              "diagnose.bat を実行して結果を確認してください。");
                    return RuntimeCheckFailed;
                }

                if (!CanAcquireRunningLock(root))
                {
                    activationServer?.SetTerminalFailure();
                    var reason = recoveredAbandonedMutex
                        ? "ランチャーの異常終了後も既存の画面が動作している可能性があります。"
                        : "既存の画面が動作している可能性があります。";
                    ShowError(reason + "\n二重起動を防止しました。既存画面を確認してください。");
                    return RunningLockHeld;
                }

                using var guiProcess = StartGuiPowerShell(shell, script, root, environment);
                NativeMethods.AllowSetForegroundWindow(guiProcess.Id);
                activationServer?.SetGuiProcess(guiProcess);

                var window = WindowActivator.WaitForMainWindow(guiProcess, TimeSpan.FromSeconds(30));
                if (window == 0)
                {
                    if (!guiProcess.HasExited)
                    {
                        activationServer?.SetTerminalFailure();
                        ShowError("Media Normalizer の画面を30秒以内に確認できませんでした。\n" +
                                  "処理は停止していません。diagnose.bat を実行して結果を確認してください。");
                        return WindowReadyTimeout;
                    }
                }
                else
                {
                    activationServer?.SetWindowReady(window);
                }

                guiProcess.WaitForExit();
                var guiExit = guiProcess.ExitCode;
                activationServer?.SetTerminalFailure();
                if (guiExit != 0)
                {
                    ShowError("Media Normalizer の起動に失敗しました。\n" +
                              $"終了コード: {guiExit}\n" +
                              "diagnose.bat を実行して結果を確認してください。");
                    return GuiChildFailed;
                }

                return 0;
            }
            finally
            {
                activationServer?.Dispose();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
            ShowError("Media Normalizer を起動できませんでした。\n" +
                      "diagnose.bat を実行して結果を確認してください。");
            return 1;
        }
        finally
        {
            if (mutexTaken)
            {
                try
                {
                    mutex?.ReleaseMutex();
                }
                catch (ApplicationException)
                {
                }
            }
            mutex?.Dispose();
        }
    }

    private static int ActivateExisting(string pipeName)
    {
        var result = ActivationClient.RequestActivation(pipeName);
        if (result.Status is ActivationStatus.Activated or ActivationStatus.Flashed or ActivationStatus.Pending)
            return 0;

        if (result.Status == ActivationStatus.Unavailable)
        {
            ShowError("既存の Media Normalizer へ接続できませんでした。\n" +
                      "タスクバーの既存画面を確認してください。");
            return ActivationUnavailable;
        }

        ShowError("既存の Media Normalizer の画面を確認できませんでした。\n" +
                  "タスクバーの既存画面を確認してください。");
        return ActivationInvalid;
    }

    private static string RequireFile(string root, string relative)
    {
        var path = Path.GetFullPath(Path.Combine(root, relative));
        if (!File.Exists(path)) throw new FileNotFoundException($"必須ファイルがありません: {relative}", path);
        return path;
    }

    private static string FindShell()
    {
        var pathValue = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var name in new[] { "pwsh.exe", "powershell.exe" })
        {
            var path = pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
                .Select(p => Environment.ExpandEnvironmentVariables(p.Trim().Trim('"')))
                .Where(p => !string.IsNullOrWhiteSpace(p))
                .Select(p => Path.Combine(p, name))
                .FirstOrDefault(File.Exists);
            if (path is not null) return path;
        }

        var windowsPowerShell = Path.Combine(
            Environment.SystemDirectory,
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (File.Exists(windowsPowerShell)) return windowsPowerShell;

        throw new FileNotFoundException("PowerShell 7 または Windows PowerShell 5.1 が必要です。");
    }

    private static ProcessStartInfo CreatePowerShellStartInfo(string shell, string script,
        IEnumerable<string> args, string root, IReadOnlyDictionary<string, string> environment)
    {
        var start = new ProcessStartInfo(shell)
        {
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-ExecutionPolicy");
        start.ArgumentList.Add("Bypass");
        start.ArgumentList.Add("-File");
        start.ArgumentList.Add(script);
        foreach (var arg in args) start.ArgumentList.Add(arg);
        foreach (var pair in environment) start.Environment[pair.Key] = pair.Value;
        start.Environment["PATH"] = string.Join(Path.PathSeparator,
            Path.Combine(root, @"runtime\ffmpeg\bin"),
            Path.Combine(root, @"runtime\python"),
            start.Environment["PATH"]);
        return start;
    }

    private static int RunPowerShellAndWait(string shell, string script, IEnumerable<string> args,
        string root, IReadOnlyDictionary<string, string> environment)
    {
        using var process = Process.Start(CreatePowerShellStartInfo(shell, script, args, root, environment))
            ?? throw new Win32Exception("PowerShellを起動できませんでした。");
        process.WaitForExit();
        return process.ExitCode;
    }

    private static Process StartGuiPowerShell(string shell, string script, string root,
        IReadOnlyDictionary<string, string> environment) =>
        Process.Start(CreatePowerShellStartInfo(shell, script, [], root, environment))
        ?? throw new Win32Exception("PowerShellを起動できませんでした。");

    private static bool CanAcquireRunningLock(string root)
    {
        try
        {
            using var stream = new FileStream(
                Path.Combine(root, ".media-normalizer-running.lock"),
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None);
            return true;
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

    private static string BuildPipeName(string pathHash)
    {
        var sid = WindowsIdentity.GetCurrent().User?.Value ?? "unknown-user";
        var userHash = StableHash(sid);
        var sessionId = Process.GetCurrentProcess().SessionId;
        return $"MediaNormalizer-Activation-{pathHash}-{userHash}-{sessionId}";
    }

    private static string StableHash(string value)
    {
        var canonical = Path.IsPathFullyQualified(value)
            ? Path.TrimEndingDirectorySeparator(Path.GetFullPath(value)).ToUpperInvariant()
            : value;
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))[..16];
    }

    private static void ShowError(string message)
    {
        _ = NativeMethods.MessageBox(0, message, Product, 0x10);
    }
}

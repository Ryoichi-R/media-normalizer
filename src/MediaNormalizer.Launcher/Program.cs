using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace MediaNormalizer.Launcher;

internal static partial class Program
{
    private const string Product = "Media Normalizer";

    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBox(nint owner, string text, string caption, uint type);

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
            var mutexName = $"Local\\MediaNormalizer-App-{StablePathHash(root)}";

            mutex = new Mutex(false, mutexName);
            try
            {
                mutexTaken = mutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                mutexTaken = true;
            }
            if (!mutexTaken)
            {
                Show("Media Normalizer は既に起動しています。");
                return 2;
            }

            var environment = new Dictionary<string, string>
            {
                ["MEDIA_NORMALIZER_RUNTIME_ROOT"] = Path.Combine(root, "runtime"),
                ["FFMPEG_PATH"] = ffmpeg,
                ["FFPROBE_PATH"] = ffprobe,
                ["MEDIA_NORMALIZER_PYTHON"] = python
            };

            var checkExit = RunPowerShell(shell, runtimeCheck, [], root, environment);
            if (checkExit != 0)
            {
                Show($"同梱ランタイムの確認に失敗しました。終了コード: {checkExit}");
                return checkExit;
            }
            return RunPowerShell(shell, script, args, root, environment);
        }
        catch (Exception ex)
        {
            Show(ex.Message);
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

    private static int RunPowerShell(string shell, string script, IEnumerable<string> args,
        string root, IReadOnlyDictionary<string, string> environment)
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
        using var process = Process.Start(start) ?? throw new Win32Exception("PowerShellを起動できませんでした。");
        process.WaitForExit();
        return process.ExitCode;
    }

    private static string StablePathHash(string path)
    {
        var canonical = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)).ToUpperInvariant();
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))[..16];
    }

    private static void Show(string message) => MessageBox(0, message, Product, 0x10);
}

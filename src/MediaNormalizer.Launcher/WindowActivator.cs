using System.Diagnostics;

namespace MediaNormalizer.Launcher;

internal enum ActivationStatus
{
    Activated,
    Flashed,
    Pending,
    Unavailable,
    Invalid
}

internal readonly record struct ActivationResult(ActivationStatus Status, int ProcessId = 0, nint Window = 0);

internal static class WindowActivator
{
    private const string ProductWindowTitle = "メディア音量正規化ツール";

    internal static nint WaitForMainWindow(Process process, TimeSpan timeout)
    {
        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < timeout)
        {
            if (process.HasExited) return 0;
            process.Refresh();
            var window = process.MainWindowHandle;
            if (IsProductWindow(window, process.Id)) return window;

            window = FindProductWindow(process.Id);
            if (window != 0) return window;
            Thread.Sleep(50);
        }
        return 0;
    }

    internal static ActivationResult Activate(int processId, nint window)
    {
        if (!IsProductWindow(window, processId)) return new(ActivationStatus.Invalid, processId, window);

        if (NativeMethods.IsIconic(window)) NativeMethods.ShowWindow(window, NativeMethods.SwRestore);
        if (NativeMethods.SetForegroundWindow(window) || NativeMethods.GetForegroundWindow() == window)
            return new(ActivationStatus.Activated, processId, window);

        if (IsTaskbarEligible(window) && NativeMethods.GetForegroundWindow() != window)
        {
            var info = new NativeMethods.FlashWindowInfo
            {
                Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.FlashWindowInfo>(),
                Window = window,
                Flags = 0x00000003 | 0x0000000C,
                Count = 3,
                Timeout = 0
            };
            if (NativeMethods.FlashWindowEx(ref info))
                return new(ActivationStatus.Flashed, processId, window);
        }

        return new(ActivationStatus.Invalid, processId, window);
    }

    internal static unsafe bool IsProductWindow(nint window, int processId)
    {
        if (window == 0 || !NativeMethods.IsWindow(window) || !NativeMethods.IsWindowVisible(window)) return false;
        var windowThread = NativeMethods.GetWindowThreadProcessId(window, out var actualProcessId);
        if (windowThread == 0) return false;
        if (actualProcessId != (uint)processId || NativeMethods.GetWindow(window, NativeMethods.GwOwner) != 0) return false;

        const int titleCapacity = 256;
        var title = stackalloc char[titleCapacity];
        var titleLength = NativeMethods.GetWindowText(window, title, titleCapacity);
        return titleLength > 0 && new ReadOnlySpan<char>(title, titleLength).SequenceEqual(ProductWindowTitle);
    }

    private static nint FindProductWindow(int processId)
    {
        nint result = 0;
        NativeMethods.EnumWindows((window, _) =>
        {
            if (!IsProductWindow(window, processId)) return true;
            result = window;
            return false;
        }, 0);
        return result;
    }

    private static bool IsTaskbarEligible(nint window)
    {
        if (!NativeMethods.IsWindowVisible(window) || NativeMethods.GetWindow(window, NativeMethods.GwOwner) != 0)
            return false;
        var extendedStyle = NativeMethods.GetWindowLongPtr(window, NativeMethods.GwlExStyle).ToInt64();
        return (extendedStyle & NativeMethods.WsExToolWindow) == 0;
    }
}

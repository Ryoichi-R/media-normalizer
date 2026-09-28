using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;
using MediaNormalizer.Gui.Services;

namespace MediaNormalizer.Gui;

internal static class Program
{
    internal static GuiRuntime? Runtime { get; private set; }
    [STAThread]
    public static int Main(string[] args)
    {
        var resources = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        var storage = Path.GetDirectoryName(SettingsStore.GetDefaultSettingsPath())!;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--resources" && i + 1 < args.Length) resources = args[++i];
            else if (args[i] == "--storage-root" && i + 1 < args.Length) storage = args[++i];
            else { Console.Error.WriteLine("Unknown or incomplete argument: " + args[i]); return 2; }
        }
        Runtime = new GuiRuntime(resources, storage);
        FileStream instanceLock;
        try { instanceLock = WorkerSupervisor.AcquireGuiInstanceLock(Runtime.StorageRoot); }
        catch (InvalidOperationException)
        {
            if (GuiActivationChannel.ActivateExistingAsync(Runtime.StorageRoot).GetAwaiter().GetResult()) return 0;
            Console.Error.WriteLine("起動済みの画面への接続に失敗しました。しばらく待って再試行してください。");
            return 2;
        }
        using (instanceLock) return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<NormalizerApplication>().UsePlatformDetect();
}

public sealed class NormalizerApplication : Application
{
    public override void Initialize() => Styles.Add(new FluentTheme());
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop && Program.Runtime is { } runtime)
        {
            var window = new MainWindow(runtime);
            desktop.MainWindow = window;
            void Activate() => Dispatcher.UIThread.Post(() => { window.Show(); window.WindowState = WindowState.Normal; window.Activate(); });
            var activation = new GuiActivationChannel(runtime.StorageRoot, Activate);
            if (TryGetFeature(typeof(IActivatableLifetime)) is IActivatableLifetime lifetime) lifetime.Activated += (_, _) => Activate();
            desktop.Exit += (_, _) => { activation.Dispose(); };
        }
        base.OnFrameworkInitializationCompleted();
    }
}

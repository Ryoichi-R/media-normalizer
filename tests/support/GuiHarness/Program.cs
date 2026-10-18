using System.IO.Pipes;
using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.LogicalTree;
using Avalonia.Interactivity;
using Avalonia.Themes.Fluent;
using System.Text.Json;
using MediaNormalizer.Gui;
using MediaNormalizer.Gui.Services;


if (args.Length == 1 && args[0] == "--build-info-only")
{
    const string infoJson = """
    {"schemaVersion":1,"appName":"Media Normalizer","productVersion":"1.1.0","sourceRevision":"0123456789ab","hasUncommittedChanges":false,"builtAtUtc":"2026-10-18T03:00:00.1234567Z","targetRuntime":"osx-arm64"}
    """;
    var known = AppBuildInfo.FromJson(infoJson);
    var text = known.GetDisplayText("Windows", "x64");
    Check(text.Split('\n').Length == 6 && text.EndsWith("実行版: Windows／x64",StringComparison.Ordinal), "Six fields and process architecture");
    Check(text.Contains("ビルド日時: 2026-10-18 03:00:00 UTC",StringComparison.Ordinal), "UTC build time");
    Check(!text.Contains("osx-arm64",StringComparison.Ordinal), "RID never appears in six fields");
    var unknown = AppBuildInfo.FromJson(infoJson.Replace("\"0123456789ab\"", "null",StringComparison.Ordinal).Replace("\"hasUncommittedChanges\":false", "\"hasUncommittedChanges\":null",StringComparison.Ordinal));
    Check(unknown.GetDisplayText().Contains("未コミット変更の有無: 不明",StringComparison.Ordinal), "Unknown Git is not clean");
    foreach (var json in new[] { "{}", "[]", infoJson.Replace("false", "\"false\"",StringComparison.Ordinal), infoJson.Replace("03:00:00.1234567Z", "03:00:00+09:00",StringComparison.Ordinal), infoJson.Replace("1.1.0", "1.1.0+mac",StringComparison.Ordinal), infoJson.Replace("0123456789ab", "/Users/example",StringComparison.Ordinal) })
    {
        var rejected = false;
        try { AppBuildInfo.FromJson(json); } catch (InvalidDataException) { rejected = true; }
        Check(rejected, "Malformed information rejected");
    }
    using var infoSession = HeadlessUnitTestSession.StartNew(typeof(MediaNormalizer.Gui.Tests.TestApplication));
    await infoSession.Dispatch(async () =>
    {
        string? copied = null;
        var infoWindow = new SettingsWindow(known, value => { copied = value; return Task.CompletedTask; });
        infoWindow.Show();
        Check(await infoWindow.CopyInformationAsync(), "Copy succeeds");
        Check(copied == infoWindow.InformationText, "Copy matches display");
        using (var frame = infoWindow.CaptureRenderedFrame()) frame?.Save(Path.Combine(Environment.CurrentDirectory,"settings-window.png"));
        infoWindow.Close();
        var failed = new SettingsWindow(unknown, _ => throw new IOException("fixture"));
        failed.Show();
        Check(!await failed.CopyInformationAsync() && failed.IsVisible, "Copy failure keeps window open");
        failed.Close();
        var noClipboard = new SettingsWindow(unknown);
        Check(!await noClipboard.CopyInformationAsync(), "Missing clipboard reports failure");
        noClipboard.Close();
        var stateRoot = Path.Combine(Path.GetTempPath(),"mn-info-harness-" + Guid.NewGuid().ToString("N"));
        var main = new MainWindow(new GuiRuntime(Path.Combine(stateRoot,"no-runtime"),stateRoot));
        main.Show();
        await WaitAsync(() => main.CurrentStatus.StartsWith("起動できません",StringComparison.Ordinal));
        var settingsButton = main.GetLogicalDescendants().OfType<Button>().Single(b => Equals(b.Content,"設定"));
        settingsButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        settingsButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(main.OwnedWindows.Count == 1 && !main.CanRun, "Settings works during diagnostic failure without enabling run");
        main.OwnedWindows.Single().Close();
        main.Close();
    }, default);
    Console.WriteLine("Build information and headless settings checks passed.");
    return 0;
}

if (args.Length is not (3 or 4)) { Console.Error.WriteLine("GuiHarness <resources> <fixture-directory> <new-state-directory>"); return 2; }
var resources = Path.GetFullPath(args[0]);
var fixtures = Path.GetFullPath(args[1]);
var state = Path.GetFullPath(args[2]);
Directory.CreateDirectory(state);
var userPresetsPath = Path.Combine(state,"presets.user.json");
await File.WriteAllTextAsync(userPresetsPath,"""
{"presets":[{"name":"Custom","target":-18,"truePeak":-2,"bitrate":"128k","sampleRate":44100},{"name":"Invalid","target":8,"truePeak":-2,"sampleRate":44100}]}
""");
var warnings = new List<string>();
var presets = PresetStore.Read(Path.Combine(resources,"assets","presets.json"),userPresetsPath,warnings.Add);
Check(presets.Any(p => p.GetProperty("name").GetString() == "Custom"),"Custom preset loaded");
Check(!presets.Any(p => p.GetProperty("name").GetString() == "Invalid") && warnings.Count == 1,"Invalid preset excluded");
var activationRoot = Path.Combine(state,"activation");
var activations = 0;
using (var channel = new GuiActivationChannel(activationRoot, () => Interlocked.Increment(ref activations)))
{
    Check(await GuiActivationChannel.ActivateExistingAsync(activationRoot), "Activation ACK missing");
    using var descriptor = JsonDocument.Parse(File.ReadAllText(Path.Combine(activationRoot,"run","gui-instance.json")));
    var endpoint = descriptor.RootElement;
    foreach (var payload in new[] {
        "{invalid",
        JsonSerializer.Serialize(new { schemaVersion = 2, command = "activate", id = Guid.NewGuid(), instanceId = endpoint.GetProperty("instanceId").GetGuid() }),
        JsonSerializer.Serialize(new { schemaVersion = 1, command = "activate", id = Guid.NewGuid(), instanceId = Guid.NewGuid() }),
        new string('x',1026) })
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var pipe = new NamedPipeClientStream(".",endpoint.GetProperty("pipeName").GetString()!,PipeDirection.InOut,PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(deadline.Token);
        await pipe.WriteAsync(Encoding.UTF8.GetBytes(payload + "\n"),deadline.Token);
        await pipe.FlushAsync(deadline.Token);
        using var reader = new StreamReader(pipe);
        Check(await reader.ReadLineAsync(deadline.Token) is null,"Invalid activation rejected");
    }
    Check(activations == 1,"Invalid requests never activate");
    Check(await GuiActivationChannel.ActivateExistingAsync(activationRoot),"Listener survives malformed requests");
}
using (var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(200)))
    Check(!await GuiActivationChannel.ActivateExistingAsync(activationRoot,timeout.Token),"Stale endpoint times out");
var startup = GuiActivationChannel.ActivateExistingAsync(activationRoot);
await Task.Delay(100);
using (var replacement = new GuiActivationChannel(activationRoot,() => { }))
    Check(await startup,"Starting instance replaces stale endpoint");
using var session = HeadlessUnitTestSession.StartNew(typeof(MediaNormalizer.Gui.Tests.TestApplication));
await session.Dispatch(async () =>
{
    var runtime = new GuiRuntime(resources,state);
    var window = new MainWindow(runtime);
    window.Show();
    await WaitAsync(() => window.IsReady || window.CurrentStatus.StartsWith("起動できません",StringComparison.Ordinal));
    Check(window.IsReady,"GUI initialization: " + window.CurrentStatus);
    Check(!window.CanRun,"Run disabled before scan");
    var boxes = window.GetLogicalDescendants().OfType<TextBox>().Where(b => !b.IsReadOnly).ToArray();
    boxes[0].Text = fixtures; boxes[1].Text = Path.Combine(state,"output");
    await window.ScanAsync();
    Check(window.FileCount == 8,"Core scan finds eight fixtures");
    Check(window.CanRun,"Run enabled after scan");
    var format = window.GetLogicalDescendants().OfType<ComboBox>().Single(b => b.Items.Cast<object?>().Any(v => Equals(v,"flac")));
    format.SelectedItem = "flac";
    Check(!window.CanRun,"Changing output format requires rescan");
    await window.ScanAsync();
    Check(window.CanRun,"Rescan enables run");
    var selection = window.GetLogicalDescendants().OfType<CheckBox>().Where(b => b.Content is null).ToArray();
    selection[0].IsChecked = false;
    await window.ScanAsync();
    Check(window.GetLogicalDescendants().OfType<CheckBox>().First(b => b.Content is null).IsChecked == false,"Selection survives rescan");

    using (var frame = window.CaptureRenderedFrame()) frame?.Save(Path.Combine(state,"window.png"));
    boxes[0].Text = Path.Combine(fixtures,"audio-dynamic.wav");
    await window.ScanAsync();
    Check(window.FileCount == 1 && window.CanRun,"Single-file normalization ready");
    var run = window.GetLogicalDescendants().OfType<Button>().Single(b => Equals(b.Content,"実行"));
    run.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    await WaitAsync(() => window.OwnedWindows.Count > 0);
    var confirmation = window.OwnedWindows.Single();
    confirmation.GetLogicalDescendants().OfType<Button>().Single(b => Equals(b.Content,"この内容で実行")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    await WaitAsync(() => window.CurrentStatus == "処理が完了しました。" || window.CurrentStatus.Contains("復旧が必要",StringComparison.Ordinal) || window.CurrentStatus.StartsWith("処理が終了",StringComparison.Ordinal));
    Check(window.CurrentStatus == "処理が完了しました。","GUI normalization completed: " + window.CurrentStatus);
    var report = Directory.GetFiles(Path.Combine(state,"output"),"media-normalizer-report-*.json").Single();
    using (var data = JsonDocument.Parse(await File.ReadAllTextAsync(report)))
        Check(data.RootElement.GetProperty("summary").GetProperty("normalized").GetInt32() == 1,"GUI report normalized one file");
    Check(!window.CanRun,"Run requires confirmation scan after completion");
    if (args.Length == 4)
    {
        boxes[0].Text = Path.GetFullPath(args[3]);
        await window.ScanAsync();
        run.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await WaitAsync(() => window.OwnedWindows.Count > 0);
        window.OwnedWindows.Single().GetLogicalDescendants().OfType<Button>().Single(b => Equals(b.Content,"この内容で実行")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await WaitAsync(() =>
        {
            using var record = JsonDocument.Parse(File.ReadAllText(Path.Combine(state,"run","active-run.json")));
            return record.RootElement.GetProperty("status").GetString() == "running" && record.RootElement.GetProperty("processes").GetArrayLength() > 1;
        });
        window.GetLogicalDescendants().OfType<Button>().Single(b => Equals(b.Content,"キャンセル")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await WaitAsync(() => window.CurrentStatus == "キャンセルと回収が完了しました。" || window.CurrentStatus.StartsWith("復旧が必要",StringComparison.Ordinal));
        Check(window.CurrentStatus == "キャンセルと回収が完了しました。","GUI cancellation: " + window.CurrentStatus);
        using var completed = JsonDocument.Parse(File.ReadAllText(Path.Combine(state,"run","active-run.json")));
        Check(completed.RootElement.GetProperty("status").GetString() == "completed","Cancellation record completed");
    }
    boxes[0].Text = fixtures;
    window.Close();
    var values = new SettingsStore(Path.Combine(state,"settings.json")).Read();
    Check(values.Values.InputDir == fixtures,"Settings persisted");
    var invalid = new MainWindow(new GuiRuntime(Path.Combine(state,"missing-runtime"),Path.Combine(state,"invalid")));
    invalid.Show();
    await WaitAsync(() => invalid.CurrentStatus.StartsWith("起動できません",StringComparison.Ordinal));
    Check(!invalid.CanRun,"Missing bundled runtime blocks run");
    invalid.Close();
    return true;
}, CancellationToken.None);
Console.WriteLine("GUI headless initialization, Core scan, invalidation, settings, activation and missing-runtime checks passed.");
return 0;

static void Check(bool condition,string message) { if (!condition) throw new InvalidOperationException(message); }
static async Task WaitAsync(Func<bool> condition)
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
    while (!condition()) await Task.Delay(50,timeout.Token);
}
namespace MediaNormalizer.Gui.Tests
{
public sealed class TestApplication : Application
{
    public override void Initialize() => Styles.Add(new FluentTheme());
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<TestApplication>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
}

}

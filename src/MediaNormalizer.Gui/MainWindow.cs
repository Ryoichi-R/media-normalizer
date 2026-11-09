using System.Globalization;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using MediaNormalizer.Gui.Services;

namespace MediaNormalizer.Gui;

[System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1001", Justification = "Cancellation sources are disposed in the awaited operation finally; window closing waits for completion.")]
public sealed class MainWindow : Window
{
    private static readonly string[] PresetDescriptionFields = ["purpose", "basis", "warning"];
    private readonly GuiRuntime _runtime;
    private readonly SettingsStore _settings;
    private readonly SettingsReadResult _saved;
    private readonly TextBox _input = new() { Watermark = "入力フォルダ（またはファイルを追加）" };
    private readonly TextBox _output = new() { Watermark = "出力フォルダ" };
    private readonly ComboBox _format = new() { MinWidth = 240 };
    private readonly StackPanel _migrationNotice = new() { IsVisible = false, Spacing = 6 };
    private string[] _outputSelections = [];
    private string[] _scanPaths = [];
    private string? _scanRoot;
    private string? _scanStatus;
    private string? _lastMode;
    private bool _migrationPending;
    private readonly ComboBox _presets = new() { MinWidth = 250 };
    private readonly NumericUpDown _target = new() { Minimum = -70, Maximum = -5, Value = -16, Width = 140 };
    private readonly NumericUpDown _peak = new() { Minimum = -9, Maximum = 0, Value = -1, Width = 130 };
    private readonly NumericUpDown _speed = new() { Minimum = 50, Maximum = 200, Increment = 10, Value = 100, Width = 130 };
    private readonly ComboBox _collision = new() { ItemsSource = new[] { "rename", "skip", "overwrite" }, SelectedIndex = 0, MinWidth = 110 };
    private readonly CheckBox _analyze = new() { Content = "解析のみ" };
    private readonly CheckBox _recurse = new() { Content = "サブフォルダを検索", IsChecked = true };
    private readonly CheckBox _hierarchy = new() { Content = "出力階層を維持", IsChecked = true };
    private readonly CheckBox _skip = new() { Content = "正規化不要ならコピー", IsChecked = true };
    private readonly TextBlock _basis = new() { TextWrapping = Avalonia.Media.TextWrapping.Wrap };
    private readonly TextBlock _status = new() { Text = "起動診断中…", FontSize = 18 };
    private readonly ProgressBar _progress = new() { Minimum = 0, Maximum = 100, Height = 10 };
    private readonly TextBox _log = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = Avalonia.Media.TextWrapping.Wrap, MinHeight = 100 };
    private readonly StackPanel _rowsPanel = new() { Spacing = 4 };
    private readonly List<FileRow> _rows = [];
    private readonly Dictionary<string, (bool Selected, decimal? Speed)> _rowState = new(StringComparer.Ordinal);
    private decimal? _previousScanSpeed;
    private readonly List<string> _paths = [];
    private readonly List<JsonElement> _presetValues = [];
    private readonly Button _scan = new() { Content = "確認（スキャン）" };
    private readonly Button _run = new() { Content = "実行", IsEnabled = false };
    private readonly Button _cancel = new() { Content = "キャンセル", IsEnabled = false };
    private readonly StackPanel _options = new() { Spacing = 8 };
    private SettingsWindow? _settingsWindow;
    private bool _busy;
    private bool _ready;
    private bool _scanned;
    private bool _blocked;
    private bool _closeAfterRun;
    private CancellationTokenSource? _cancelSource;
    public string CurrentStatus => _status.Text ?? string.Empty;
    public bool CanRun => _run.IsEnabled;
    public bool IsReady => _ready;
    public int FileCount => _rows.Count;

    public MainWindow(GuiRuntime runtime)
    {
        _runtime = runtime;
        _settings = new SettingsStore(Path.Combine(runtime.StorageRoot, "settings.json"));
        _saved = _settings.Read();
        Icon = new WindowIcon(Avalonia.Platform.AssetLoader.Open(new Uri("avares://MediaNormalizer.Gui/Assets/media-normalizer-icon.png")));
        Title = "Media Normalizer"; Width = 1180; Height = 830; MinWidth = 1100; MinHeight = 650;
        _input.Text = _saved.Values.InputDir; _output.Text = _saved.Values.OutputDir;
        _lastMode = _saved.SavedLastMode;
        _migrationPending = _saved.RequiresOutputMigration;
        var files = new Button { Content = "ファイル追加" };
        var folder = new Button { Content = "入力フォルダ" };
        var output = new Button { Content = "出力先" };
        var clear = new Button { Content = "入力をクリア" };
        files.Click += async (_, _) => await AddFilesAsync();
        folder.Click += async (_, _) => { var selected = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false }); if (selected.Count > 0) { _paths.Clear(); _input.Text = selected[0].TryGetLocalPath(); } };
        output.Click += async (_, _) => { var selected = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false }); if (selected.Count > 0) _output.Text = selected[0].TryGetLocalPath(); };
        clear.Click += (_, _) => { _paths.Clear(); _input.Text = ""; _rows.Clear(); _rowState.Clear(); _rowsPanel.Children.Clear(); InvalidateScan(); };
        _options.Children.Add(Line(files, folder, output, clear));
        _options.Children.Add(_input); _options.Children.Add(_output);
        _options.Children.Add(Line(Label("プリセット"), _presets, Label("出力形式"), _format));
        _options.Children.Add(_migrationNotice);
        _options.Children.Add(Line(Label("目標 LUFS"), _target, Label("上限 dBTP"), _peak, Label("速度 %"), _speed, Label("同名出力"), _collision));
        _options.Children.Add(Line(_analyze, _recurse, _hierarchy, _skip));
        _options.Children.Add(_basis);
        var body = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,2*,Auto,3*"), Margin = new Thickness(20), RowSpacing = 10 };
        var settings = new Button { Content = "設定" };
        settings.Click += (_, _) =>
        {
            if (_settingsWindow is not null) { _settingsWindow.Activate(); return; }
            _settingsWindow = new SettingsWindow(AppBuildInfo.Load());
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
            _settingsWindow.Show(this);
        };
        var header = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(settings, Dock.Right);
        header.Children.Add(settings);
        _status.TextWrapping = Avalonia.Media.TextWrapping.Wrap;
        header.Children.Add(_status);
        body.Children.Add(header);
        AddAt(body, new ScrollViewer { Content = _options, MaxHeight = 300, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto }, 1);
        AddAt(body, Line(_scan, _run, _cancel, Label("一覧のチェックを外すと処理対象から除外します。")), 2);
        AddAt(body, new ScrollViewer { Content = _rowsPanel, MinHeight = 60 }, 3);
        AddAt(body, _progress, 4); AddAt(body, _log, 5); Content = body;
        ScrollViewer.SetVerticalScrollBarVisibility(_log, Avalonia.Controls.Primitives.ScrollBarVisibility.Visible);
        _scan.Click += async (_, _) => await ScanAsync();
        _run.Click += async (_, _) => { try { await NormalizeAsync(); } catch (Exception exception) { AppendLog(exception.Message); _status.Text = "入力内容をご確認ください。"; } };
        _cancel.Click += (_, _) => { _cancelSource?.Cancel(); _status.Text = "キャンセル・回収完了を待っています…"; _cancel.IsEnabled = false; };
        _input.TextChanged += (_, _) => InvalidateScan(); _output.TextChanged += (_, _) => InvalidateScan();
        _format.SelectionChanged += (_, _) => InvalidateScan();
        _collision.SelectionChanged += (_, _) => InvalidateScan();
        _presets.SelectionChanged += (_, _) => ApplyPreset();
        foreach (var box in new[] { _analyze, _recurse, _hierarchy, _skip }) box.IsCheckedChanged += (_, _) => InvalidateScan();
        foreach (var number in new[] { _target, _peak, _speed }) number.ValueChanged += (_, _) => InvalidateScan();
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, (_, e) => { e.DragEffects = _busy ? DragDropEffects.None : DragDropEffects.Copy; e.Handled = true; });
        AddHandler(DragDrop.DropEvent, async (_, e) =>
        {
            if (_busy || !_ready) return;
            var items = e.DataTransfer.TryGetFiles();
            if (items is null) return;
            foreach (var item in items) if (item.TryGetLocalPath() is { } path) _paths.Add(path);
            InvalidateScan(); await ScanAsync();
        });
        Opened += async (_, _) => await InitializeAsync();
        Closing += (_, e) =>
        {
            if (_busy) { e.Cancel = true; _closeAfterRun = true; _cancelSource?.Cancel(); _status.Text = "終了前に処理と回収の完了を待っています…"; }
            else SaveSettings();
        };
        RefreshButtons();
    }
    private static TextBlock Label(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center };
    private static StackPanel Line(params Control[] controls)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var control in controls) line.Children.Add(control);
        return line;
    }
    private static void AddAt(Grid grid, Control control, int row) { Grid.SetRow(control, row); grid.Children.Add(control); }
    private void InvalidateScan() { _scanned = false; UpdatePresetDescription(); RefreshButtons(); }
    private void RefreshButtons()
    {
        _options.IsEnabled = _ready && !_busy && !_blocked;
        _scan.IsEnabled = _ready && !_busy && !_blocked;
        var selected = _rows.Where(r => r.IsSelected).ToArray();
        if (_scanned) UpdateRowWarnings(selected);
        _run.IsEnabled = _ready && !_busy && !_blocked && _scanned && selected.Length > 0 &&
            selected.All(r => !r.SpeedBlocked) && !string.IsNullOrWhiteSpace(_output.Text);
        _cancel.IsEnabled = _busy;
        _rowsPanel.IsEnabled = !_busy;
    }
    private async Task InitializeAsync()
    {
        _busy = true; RefreshButtons();
        try
        {
            await _runtime.ValidateAsync();
            using (var recovery = _runtime.CreateSupervisor())
            {
                var recovered = await recovery.RecoverExistingRunAsync();
                if (recovered.RecoveryRequired) { _blocked = true; throw new InvalidOperationException(recovered.Message); }
                if (recovered.HadExistingRun && recovered.Message is not null) AppendLog(recovered.Message);
            }
            _presetValues.AddRange(PresetStore.Read(Path.Combine(_runtime.Resources, "assets", "presets.json"), Path.Combine(_runtime.StorageRoot, "presets.user.json"), AppendLog));
            _presets.ItemsSource = _presetValues.Select(p => p.GetProperty("name").GetString()).ToArray();
            var index = _presetValues.FindIndex(p => p.GetProperty("name").GetString() == _saved.Values.LastPreset);
            _presets.SelectedIndex = Math.Max(0, index);
            var result = await ExecuteAsync(new Dictionary<string, object?> { ["cmd"] = "capabilities", ["outputSelectionProtocol"] = true });
            if (result.RecoveryRequired) throw new InvalidOperationException("ワーカーの復旧が必要です。");
            if (result.ExitCode != 0 || !_outputSelections.Contains("auto", StringComparer.Ordinal) ||
                !_outputSelections.Contains("mp3", StringComparer.Ordinal) || !_outputSelections.Contains("mp4", StringComparer.Ordinal) ||
                !_outputSelections.Contains("original-video", StringComparer.Ordinal) || !_outputSelections.Contains("audio-and-video", StringComparer.Ordinal))
                throw new InvalidOperationException("アプリとワーカーのバージョンが一致しません。");
            _ready = true; _status.Text = "入力を選び、確認を押してください。";
            foreach (var warning in _saved.Warnings) AppendLog(warning);
            ApplyPreset();
            SelectOutput(_saved.Values.LastOutputSelection ?? "auto");
            if (_migrationPending) ShowMigrationNotice();
        }
        catch (Exception exception) { _blocked = true; _status.Text = "起動できません: " + exception.Message; AppendLog(exception.Message); }
        finally { _busy = false; RefreshButtons(); if (_closeAfterRun) Close(); }
    }
    private void ApplyPreset()
    {
        if (_presets.SelectedIndex < 0 || _presets.SelectedIndex >= _presetValues.Count) return;
        var preset = _presetValues[_presets.SelectedIndex];
        _target.Value = preset.GetProperty("target").GetDecimal(); _peak.Value = preset.GetProperty("truePeak").GetDecimal();
        var selection = SelectedOutput;
        _format.ItemsSource = _outputSelections.Select(value => new OutputOption(value, OutputLabel(value))).ToArray();
        SelectOutput(selection);
        InvalidateScan();
    }
    private void UpdatePresetDescription()
    {
        if (_presets.SelectedIndex < 0 || _presets.SelectedIndex >= _presetValues.Count) return;
        var preset = _presetValues[_presets.SelectedIndex];
        var matches = _target.Value == preset.GetProperty("target").GetDecimal() && _peak.Value == preset.GetProperty("truePeak").GetDecimal();
        _basis.Text = string.Join("\n", PresetDescriptionFields.Select(k => preset.GetProperty(k).GetString())) +
            (matches ? "\n現在値はプリセットと一致しています。" : "\n現在値はプリセットから変更されています。");
    }
    private string SelectedOutput => (_format.SelectedItem as OutputOption)?.Value ?? "auto";

    private string PresetAudioFormat => _presets.SelectedIndex >= 0 && _presets.SelectedIndex < _presetValues.Count
        ? _presetValues[_presets.SelectedIndex].GetProperty("outputFormat").GetString() ?? "mp3"
        : "mp3";

    private string OutputLabel(string value) => value switch
    {
        "auto" => $"自動（動画は元の形式／音声は {PresetAudioFormat.ToUpperInvariant()}）",
        "original-video" => "元の動画形式",
        "audio-and-video" => $"音声（{PresetAudioFormat.ToUpperInvariant()}）＋元の動画形式",
        _ => value.ToUpperInvariant()
    };

    private void SelectOutput(string value)
    {
        var options = _format.Items.OfType<OutputOption>().ToArray();
        _format.SelectedItem = options.FirstOrDefault(option => option.Value == value) ??
            options.FirstOrDefault(option => option.Value == "auto");
    }

    private void ShowMigrationNotice()
    {
        var prior = _lastMode switch
        {
            "video" => "original-video",
            "both" => "audio-and-video",
            _ => PresetAudioFormat
        };
        var keep = new Button { Content = "確認" };
        var restore = new Button { Content = "以前の設定に戻す" };
        keep.Click += (_, _) => AcknowledgeMigration();
        restore.Click += (_, _) => { SelectOutput(prior); AcknowledgeMigration(); };
        _migrationNotice.Children.Add(new TextBlock
        {
            Text = $"出力形式を「自動」に切り替えました。動画は元の形式、音声はプリセット形式で出力します。AVIは音声出力です。以前の設定に相当する形式は「{OutputLabel(prior)}」です。",
            TextWrapping = Avalonia.Media.TextWrapping.Wrap
        });
        _migrationNotice.Children.Add(Line(keep, restore));
        _migrationNotice.IsVisible = true;
    }

    private void AcknowledgeMigration()
    {
        if (!SaveSettings(confirmMigration: true)) return;
        _migrationPending = false;
        _migrationNotice.IsVisible = false;
    }

    private void UpdateRowWarnings(FileRow[] selected)
    {
        var duplicates = selected.SelectMany(row => row.Destinations)
            .GroupBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Where(group => group.Count() > 1).Select(group => group.Key)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var row in _rows)
        {
            var warnings = new List<string>();
            if (row.Reason is not null) warnings.Add(row.Reason);
            if (row.Warning is not null && row.Warning != row.Reason) warnings.Add(row.Warning);
            if (row.SpeedBlocked && row.SpeedReason is not null) warnings.Add(row.SpeedReason);
            if (row.IsSelected && row.Destinations.Any(duplicates.Contains))
                warnings.Add("選択行どうしで出力予定名が重複しています。");
            row.Details.Text = warnings.Count == 0 ? row.RouteLabel : $"{row.RouteLabel} — {string.Join(" ", warnings)}";
        }
    }

    private async Task AddFilesAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = "入力メディア" });
        foreach (var file in files) if (file.TryGetLocalPath() is { } path) _paths.Add(path);
        InvalidateScan();
    }
    public async Task ScanAsync()
    {
        if (_busy || !_ready || _blocked) return;
        var paths = _paths.ToList();
        if (!string.IsNullOrWhiteSpace(_input.Text)) paths.Add(_input.Text.Trim());
        if (paths.Count == 0) { _status.Text = "入力ファイルまたはフォルダを指定してください。"; return; }
        foreach (var row in _rows.Where(row => row.Reason is null))
            _rowState[row.Path] = (row.IsSelected, row.Speed.Value);
        _rows.Clear(); _rowsPanel.Children.Clear(); _scanned = false;
        _scanRoot = null; _scanStatus = null;
        _scanPaths = paths.Distinct(StringComparer.Ordinal).ToArray();
        await WithBusyAsync(async () =>
        {
            _status.Text = "ファイルを確認中…";
            var result = await ExecuteAsync(new Dictionary<string, object?>
            {
                ["cmd"] = "scan", ["paths"] = _scanPaths, ["outputSelection"] = SelectedOutput,
                ["audioOutputFormat"] = PresetAudioFormat, ["outputDir"] = _output.Text?.Trim() ?? "",
                ["analyzeOnly"] = _analyze.IsChecked == true, ["recurse"] = _recurse.IsChecked == true,
                ["preserveHierarchy"] = _hierarchy.IsChecked == true, ["collisionPolicy"] = _collision.SelectedItem
            });
            _scanned = result.ExitCode == 0 && !result.RecoveryRequired && _scanStatus == "completed" &&
                _cancelSource?.IsCancellationRequested != true;
            if (_scanned) _previousScanSpeed = _speed.Value;
            else { _rows.Clear(); _rowsPanel.Children.Clear(); }
            if (!_blocked)
                _status.Text = _scanned ? $"{_rows.Count} 件を確認しました（対象 {_rows.Count(row => row.Reason is null)} 件）。"
                    : _scanStatus == "cancelled" || _cancelSource?.IsCancellationRequested == true
                        ? "スキャンをキャンセルしました。" : "確認に失敗しました。ログをご確認ください。";
        });
    }
    private async Task NormalizeAsync()
    {
        if (!_run.IsEnabled) return;
        if (!await ConfirmAsync() || !_run.IsEnabled) return;
        var selected = _rows.Where(r => r.IsSelected).ToArray();
        var preset = _presetValues[_presets.SelectedIndex];
        var output = Path.GetFullPath(_output.Text!.Trim());
        var command = new Dictionary<string, object?>
        {
            ["cmd"] = "normalize", ["inputPaths"] = selected.Select(r => r.Path).ToArray(), ["outputDir"] = output,
            ["outputSelection"] = SelectedOutput, ["inputRoot"] = _scanRoot, ["scanPaths"] = _scanPaths,
            ["protectedInputs"] = _rows.Select(row => row.Path).ToArray(),
            ["plannedFiles"] = selected.Select(row => new { path = row.Path, formats = row.Formats, size = row.Size, modifiedTicks = row.ModifiedTicks }).ToArray(),
            ["target"] = (double)(_target.Value ?? -16), ["truePeak"] = (double)(_peak.Value ?? -1),
            ["bitrate"] = preset.GetProperty("bitrate").GetString(), ["sampleRate"] = preset.GetProperty("sampleRate").GetInt32().ToString(CultureInfo.InvariantCulture),
            ["audioOutputFormat"] = PresetAudioFormat, ["speedPercent"] = (int)(_speed.Value ?? 100),
            ["speedPercentByPath"] = selected.ToDictionary(r => r.Path, r => (int)(r.Speed.Value ?? 100), StringComparer.Ordinal),
            ["collisionPolicy"] = _collision.SelectedItem, ["analyzeOnly"] = _analyze.IsChecked == true,
            ["skipIfNormalized"] = _skip.IsChecked == true, ["normalizationTolerance"] = 0.5,
            ["recurse"] = _recurse.IsChecked == true, ["preserveHierarchy"] = _hierarchy.IsChecked == true,
            ["reportPath"] = Path.Combine(output, "media-normalizer-report-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture) + ".json")
        };
        SaveSettings();
        await WithBusyAsync(async () =>
        {
            _status.Text = "処理中…"; _progress.Value = 0;
            var result = await ExecuteAsync(command);
            if (!_blocked) _status.Text = result.ExitCode == 3 ? "別の処理が実行中です。" : _cancelSource?.IsCancellationRequested == true ? "キャンセルと回収が完了しました。" : result.ExitCode == 0 ? "処理が完了しました。" : "処理が終了しました。失敗内容はログ・レポートをご確認ください。";
            AppendLog("レポート: " + command["reportPath"]);
            _scanned = false;
        });
    }
    private async Task<bool> ConfirmAsync()
    {
        var dialog = new Window { Title = "実行内容の確認", Width = 540, Height = 280, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var yes = new Button { Content = "この内容で実行" }; var no = new Button { Content = "戻る" };
        yes.Click += (_, _) => dialog.Close(true); no.Click += (_, _) => dialog.Close(false);
        var selected = _rows.Where(row => row.IsSelected).ToArray();
        var summary = _analyze.IsChecked == true ? $"解析対象 {selected.Length} 件" :
            string.Join(" / ", selected.SelectMany(row => row.Formats)
                .GroupBy(format => format, StringComparer.Ordinal)
                .Select(group => $"{group.Key.ToUpperInvariant()} {group.Count()} 件"));
        dialog.Content = new StackPanel { Margin = new Thickness(20), Spacing = 18, Children = {
            new TextBlock { Text = $"{summary}\n目標 {_target.Value} LUFS・上限 {_peak.Value} dBTP\n同名出力: {_collision.SelectedItem}\n出力先: {_output.Text}", TextWrapping = Avalonia.Media.TextWrapping.Wrap }, Line(yes,no) } };
        return await dialog.ShowDialog<bool>(this);
    }
    private async Task WithBusyAsync(Func<Task> action)
    {
        _busy = true; _cancelSource = new CancellationTokenSource(); RefreshButtons();
        try { await action(); }
        catch (Exception exception)
        {
            AppendLog(exception.Message);
            _status.Text = "実行状態を確認しています…";
            try
            {
                using var recovery = _runtime.CreateSupervisor();
                var recovered = await recovery.RecoverExistingRunAsync();
                _blocked |= recovered.RecoveryRequired;
            }
            catch (Exception recoveryError) { _blocked = true; AppendLog(recoveryError.Message); }
            _status.Text = _blocked ? "復旧が必要です。次の処理を停止しています。" : "処理を開始できません: " + exception.Message;
        }
        finally
        {
            _cancelSource.Dispose(); _cancelSource = null; _busy = false; RefreshButtons();
            if (_closeAfterRun) Close();
        }
    }
    private async Task<WorkerSupervisorResult> ExecuteAsync(Dictionary<string, object?> command)
    {
        using var supervisor = _runtime.CreateSupervisor(e => { var copy = e.Clone(); Dispatcher.UIThread.Post(() => HandleEvent(copy)); });
        supervisor.StatusChanged += status => Dispatcher.UIThread.Post(() =>
        {
            if (status == "recovering") _status.Text = "停止したワーカーの子プロセスを回収しています…";
            else if (status == "recovery-required") { _blocked = true; _status.Text = "復旧が必要です。次の処理を停止しています。"; }
        });
        var result = await supervisor.RunAsync(command, _cancelSource?.Token ?? CancellationToken.None);
        // Drain queued events before changing action availability or using scan results.
        await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Background);
        if (!string.IsNullOrWhiteSpace(result.StandardError)) AppendLog(result.StandardError);
        if (result.RecoveryRequired) { _blocked = true; _status.Text = "復旧が必要です。次の処理を停止しています。"; }
        return result;
    }
    private void HandleEvent(JsonElement value)
    {
        var type = value.GetProperty("type").GetString();
        switch (type)
        {
            case "capabilities-result":
                if (value.TryGetProperty("outputSelections", out var selections))
                    _outputSelections = selections.EnumerateArray().Select(item => item.GetString()!).ToArray();
                break;
            case "scan-result":
                _scanStatus = value.GetProperty("status").GetString();
                _scanRoot = value.GetProperty("inputRoot").GetString();
                if (_scanStatus != "completed") break;
                foreach (var item in value.GetProperty("files").EnumerateArray())
                {
                    var row = new FileRow(item, _analyze.IsChecked == true);
                    row.Speed.Value = _speed.Value;
                    if (row.Reason is null && _rowState.TryGetValue(row.Path, out var previous))
                    {
                        row.Selected.IsChecked = previous.Selected;
                        if (_previousScanSpeed == _speed.Value) row.Speed.Value = previous.Speed;
                    }
                    row.Selected.IsCheckedChanged += (_, _) => RefreshButtons();
                    row.Speed.ValueChanged += (_, _) => RefreshButtons();
                    _rows.Add(row); _rowsPanel.Children.Add(row.View);
                }
                break;
            case "progress":
                if (value.TryGetProperty("percent", out var percent) && percent.ValueKind == JsonValueKind.Number) _progress.Value = Math.Clamp(percent.GetDouble(),0,100);
                var phase = value.TryGetProperty("phase",out var p) ? p.GetString() : "処理中";
                _status.Text = value.TryGetProperty("eta",out var eta) && eta.ValueKind == JsonValueKind.Number ? $"{phase} — この工程は残り約 {TimeSpan.FromSeconds(Math.Clamp(eta.GetDouble(), 0, 864000)).ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture)}" : $"{phase} — 残り時間を計算中…";
                break;
            case "file-done":
                var filePath = value.GetProperty("inputPath").GetString();
                foreach (var row in _rows.Where(r => r.Path == filePath))
                {
                    var status = value.GetProperty("status").GetString();
                    if (row.Status.Text != "failed" || status == "failed") row.Status.Text = status;
                    if (value.GetProperty("message").GetString() is { } reason) ToolTip.SetTip(row.Status, reason);
                }
                break;
            case "error": case "log":
                if (value.TryGetProperty("message",out var message)) AppendLog(message.GetString() ?? "");
                break;
        }
    }
    private void AppendLog(string text)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {text}\n";
        var scroller = _log.GetVisualDescendants().OfType<ScrollViewer>().FirstOrDefault();
        var offset = scroller?.Offset ?? default;
        var follow = scroller is null || scroller.Offset.Y >= scroller.Extent.Height - scroller.Viewport.Height - 4;
        var display = _log.Text + line;
        _log.Text = display.Length > 40000 ? display[^40000..] : display;
        if (follow) _log.CaretIndex = _log.Text.Length;
        else if (scroller is not null) Dispatcher.UIThread.Post(() => scroller.Offset = offset, DispatcherPriority.Background);
        try
        {
            var path = _runtime.LogPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length + System.Text.Encoding.UTF8.GetByteCount(line) > 5 * 1024 * 1024) File.Move(path,path + ".1",true);
            File.AppendAllText(path,line);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { _status.Text = "ログの保存に失敗しました。画面内のログをご確認ください。"; }
    }
    private bool SaveSettings(bool confirmMigration = false)
    {
        if (!_ready) return false;
        var selection = _migrationPending && !confirmMigration ? null : SelectedOutput;
        var mode = selection switch
        {
            "original-video" => "video",
            "audio-and-video" => "both",
            "mp3" or "m4a" or "aac" or "flac" or "wav" or "opus" or "ogg" => "audio",
            _ => _lastMode
        };
        try
        {
            _settings.Save(new SettingsValues(_input.Text, _output.Text,
                _presets.SelectedItem as string ?? _saved.Values.LastPreset, mode, selection), _saved.ExtensionFields);
            _lastMode = mode;
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            AppendLog("設定を保存できません: " + exception.Message);
            return false;
        }
    }

    private sealed record OutputOption(string Value, string Label)
    {
        public override string ToString() => Label;
    }

    private sealed class FileRow
    {
        public string Path { get; }
        public string[] Formats { get; }
        public string[] Destinations { get; }
        public string? Reason { get; }
        public string? Warning { get; }
        public string? SpeedReason { get; }
        public long Size { get; }
        public long ModifiedTicks { get; }
        public string RouteLabel { get; }
        public bool IsSelected => Reason is null && Selected.IsChecked == true;
        public bool SpeedBlocked => SpeedReason is not null && (Speed.Value ?? 100) != 100;
        public CheckBox Selected { get; } = new();
        public NumericUpDown Speed { get; } = new() { Minimum = 50, Maximum = 200, Increment = 10, Value = 100, Width = 130 };
        public TextBlock Status { get; } = new() { Text = "未処理", VerticalAlignment = VerticalAlignment.Center };
        public TextBlock Details { get; } = new() { TextWrapping = Avalonia.Media.TextWrapping.Wrap };
        public Grid View { get; } = new() { ColumnDefinitions = new ColumnDefinitions("32,*,140,120"), ColumnSpacing = 8 };

        public FileRow(JsonElement item, bool analyze)
        {
            Path = item.GetProperty("path").GetString()!;
            Formats = item.GetProperty("formats").EnumerateArray().Select(value => value.GetString()!).ToArray();
            Destinations = item.GetProperty("destinations").EnumerateArray().Select(value => value.GetString()!).ToArray();
            Reason = item.GetProperty("reason").GetString();
            Warning = item.GetProperty("warning").GetString();
            SpeedReason = item.GetProperty("speedReason").GetString();
            Size = item.GetProperty("size").GetInt64();
            ModifiedTicks = item.GetProperty("modifiedTicks").GetInt64();
            var kind = item.GetProperty("kind").GetString() switch
            {
                "video" => "映像＋音声",
                "audio" => "音声のみ",
                "no-audio" => "音声なし",
                _ => "判定不能"
            };
            RouteLabel = Reason is not null ? kind : analyze ? $"{kind} → 解析" :
                $"{kind} → {string.Join(" ＋ ", Formats.Select(format => format.ToUpperInvariant()))}";
            Selected.IsEnabled = Reason is null;
            Selected.IsChecked = Reason is null;
            Speed.IsEnabled = Reason is null && !analyze;
            Details.Text = Reason is null ? RouteLabel : $"{RouteLabel} — {Reason}";
            ToolTip.SetTip(Details, Destinations.Length == 0 ? null : string.Join(Environment.NewLine, Destinations));
            var name = Label(System.IO.Path.GetFileName(Path));
            name.TextTrimming = Avalonia.Media.TextTrimming.CharacterEllipsis;
            ToolTip.SetTip(name, Path);
            var description = new StackPanel { Children = { name, Details } };
            View.Children.Add(Selected);
            Grid.SetColumn(description, 1); View.Children.Add(description);
            Grid.SetColumn(Speed, 2); View.Children.Add(Speed);
            Grid.SetColumn(Status, 3); View.Children.Add(Status);
        }
    }
}

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using MediaNormalizer.Gui.Services;

namespace MediaNormalizer.Gui;

public sealed class SettingsWindow : Window
{
    private readonly TextBlock _copyStatus = new();
    private readonly Func<string, Task>? _copyText;
    public string InformationText { get; }

    public SettingsWindow(AppBuildInfo info, Func<string, Task>? copyText = null)
    {
        ArgumentNullException.ThrowIfNull(info);
        _copyText = copyText;
        InformationText = info.GetDisplayText();
        Title = "設定"; Width = 620; Height = 390; MinWidth = 430; MinHeight = 330;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var body = new StackPanel { Margin = new Thickness(20), Spacing = 12 };
        body.Children.Add(new TextBlock { Text = "バージョン情報", FontSize = 20 });
        body.Children.Add(new TextBox { Text = InformationText, IsReadOnly = true, AcceptsReturn = true, TextWrapping = Avalonia.Media.TextWrapping.Wrap });
        if (!info.IsComplete) body.Children.Add(new TextBlock { Text = "ビルド情報の一部を取得できません。", TextWrapping = Avalonia.Media.TextWrapping.Wrap });
        var copy = new Button { Content = "情報をコピー", HorizontalAlignment = HorizontalAlignment.Left };
        copy.Click += async (_, _) => await CopyInformationAsync();
        body.Children.Add(copy);
        body.Children.Add(_copyStatus);
        var close = new Button { Content = "閉じる", HorizontalAlignment = HorizontalAlignment.Right };
        close.Click += (_, _) => Close();
        body.Children.Add(close);
        Content = new ScrollViewer { Content = body };
    }

    public async Task<bool> CopyInformationAsync()
    {
        try
        {
            if (_copyText is not null) await _copyText(InformationText);
            else
            {
                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard is null) { _copyStatus.Text = "コピーできませんでした。"; return false; }
                await clipboard.SetTextAsync(InformationText);
            }
            _copyStatus.Text = "コピーしました。";
            return true;
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            _copyStatus.Text = "コピーできませんでした。";
            return false;
        }
    }
}

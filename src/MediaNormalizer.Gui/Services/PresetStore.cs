using System.Globalization;
using System.Text.Json;

namespace MediaNormalizer.Gui.Services;

public static class PresetStore
{
    public static IReadOnlyList<JsonElement> Read(string basePath, string userPath, Action<string> warn)
    {
        var merged = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in new[] { basePath, userPath })
        {
            if (!File.Exists(path)) continue;
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(path));
                foreach (var value in document.RootElement.GetProperty("presets").EnumerateArray())
                {
                    var name = Text(value,"name",string.Empty).Trim();
                    if (name.Length > 0) merged[name] = value.Clone();
                }
            }
            catch (Exception exception) when (exception is IOException or JsonException or InvalidOperationException or KeyNotFoundException)
            { warn("プリセットを読み込めません: " + Path.GetFileName(path)); }
        }
        var result = new List<JsonElement>();
        foreach (var (name, value) in merged)
        {
            if (!decimal.TryParse(Text(value,"target",""),NumberStyles.Float,CultureInfo.InvariantCulture,out var target) || target is < -70 or > -5 ||
                !decimal.TryParse(Text(value,"truePeak",""),NumberStyles.Float,CultureInfo.InvariantCulture,out var peak) || peak is < -9 or > 0 ||
                !int.TryParse(Text(value,"sampleRate",""),CultureInfo.InvariantCulture,out var rate) || rate <= 0)
            { warn("範囲外または不正なプリセットを除外しました: " + name); continue; }
            result.Add(JsonSerializer.SerializeToElement(new {
                name, target, truePeak = peak, sampleRate = rate,
                bitrate = Text(value,"bitrate","192k"), outputFormat = Text(value,"outputFormat","mp3"),
                purpose = Text(value,"purpose","ユーザー定義プリセット"), basis = Text(value,"basis","根拠情報なし"), warning = Text(value,"warning","出力先の仕様を確認してください。")
            }));
        }
        if (result.Count == 0)
        {
            warn("有効なプリセットがないため既定値を使います。");
            result.Add(JsonSerializer.SerializeToElement(new { name = "デフォルト", target = -16, truePeak = -1, sampleRate = 48000, bitrate = "192k", outputFormat = "mp3", purpose = "一般向け", basis = "運用上の初期値", warning = "納品先仕様を優先してください。" }));
        }
        return result;
    }
    private static string Text(JsonElement value,string name,string fallback) => value.TryGetProperty(name,out var field) ? field.ToString() : fallback;
}

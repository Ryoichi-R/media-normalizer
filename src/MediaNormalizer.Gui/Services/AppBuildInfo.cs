using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MediaNormalizer.Gui.Services;

public sealed class AppBuildInfo
{
    private const string Unknown = "不明";
    private static readonly string[] Fields = ["appName", "builtAtUtc", "hasUncommittedChanges", "productVersion", "schemaVersion", "sourceRevision", "targetRuntime"];
    public string AppName { get; private init; } = "Media Normalizer";
    public string? ProductVersion { get; private init; }
    public string? SourceRevision { get; private init; }
    public bool? HasUncommittedChanges { get; private init; }
    public DateTimeOffset? BuiltAtUtc { get; private init; }
    public string? TargetRuntime { get; private init; }
    public bool IsComplete { get; private init; }

    public static AppBuildInfo Load()
    {
        var assembly = typeof(AppBuildInfo).Assembly;
        using var resource = assembly.GetManifestResourceStream("MediaNormalizer.BuildInfo");
        if (resource is not null)
        {
            try { using var reader = new StreamReader(resource); return FromJson(reader.ReadToEnd()); }
            catch (Exception error) when (error is JsonException or InvalidDataException or IOException) { return new AppBuildInfo(); }
        }
        return new AppBuildInfo { ProductVersion = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion };
    }

    public static AppBuildInfo FromJson(string json)
    {
        try { return ReadJson(json); }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException or OverflowException)
        { throw new InvalidDataException("BUILD_INFO_INVALID", error); }
    }

    private static AppBuildInfo ReadJson(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).SequenceEqual(Fields))
            throw new InvalidDataException("BUILD_INFO_INVALID");
        if (!root.GetProperty("schemaVersion").TryGetInt32(out var schema) || schema != 1 || root.GetProperty("appName").GetString() != "Media Normalizer")
            throw new InvalidDataException("BUILD_INFO_INVALID");
        var version = root.GetProperty("productVersion").GetString();
        if (version is null || !Regex.IsMatch(version, @"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$", RegexOptions.CultureInvariant) || !Version.TryParse(version, out var numeric) || numeric.Major > 9999 || numeric.Minor > 99 || numeric.Build > 99)
            throw new InvalidDataException("BUILD_INFO_INVALID");
        var source = root.GetProperty("sourceRevision").GetString();
        if (source is not null && !Regex.IsMatch(source, "^[0-9a-f]{12,64}$", RegexOptions.CultureInvariant)) throw new InvalidDataException("BUILD_INFO_INVALID");
        var dirty = root.GetProperty("hasUncommittedChanges");
        if (dirty.ValueKind is not (JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False)) throw new InvalidDataException("BUILD_INFO_INVALID");
        var timestamp = root.GetProperty("builtAtUtc").GetString();
        if (timestamp is null || !timestamp.EndsWith('Z') || !DateTimeOffset.TryParseExact(timestamp, ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'"], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var built))
            throw new InvalidDataException("BUILD_INFO_INVALID");
        var runtime = root.GetProperty("targetRuntime").GetString();
        if (runtime is not ("win-x64" or "win-arm64" or "osx-arm64")) throw new InvalidDataException("BUILD_INFO_INVALID");
        return new AppBuildInfo { ProductVersion = version, SourceRevision = source, HasUncommittedChanges = dirty.ValueKind == JsonValueKind.Null ? null : dirty.GetBoolean(), BuiltAtUtc = built.ToUniversalTime(), TargetRuntime = runtime, IsComplete = true };
    }

    public string GetDisplayText(string? platform = null, string? architecture = null)
    {
        platform ??= OperatingSystem.IsMacOS() ? "macOS" : OperatingSystem.IsWindows() ? "Windows" : "Linux";
        architecture ??= RuntimeInformation.ProcessArchitecture switch { Architecture.Arm64 => "ARM64", Architecture.Arm => "ARM", Architecture.X64 => "x64", Architecture.X86 => "x86", _ => Unknown };
        return string.Join('\n', $"アプリ名: {AppName}", $"バージョン: {ProductVersion ?? Unknown}", $"ソース識別子: {SourceRevision ?? Unknown}",
            $"未コミット変更の有無: {(HasUncommittedChanges is null ? Unknown : HasUncommittedChanges.Value ? "あり" : "なし")}",
            $"ビルド日時: {BuiltAtUtc?.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture) ?? Unknown}", $"実行版: {platform}／{architecture}");
    }
}

using System.Globalization;
using System.Security;
using System.Text;
using System.Text.Json;

namespace MediaNormalizer.Gui.Services;

/// <summary>Values recognized by Settings schema version 2.</summary>
public sealed record SettingsValues(string? InputDir, string? OutputDir, string? LastPreset, string? LastMode)
{
    public static SettingsValues Default => new(string.Empty, string.Empty, "デフォルト", "audio");
}

/// <summary>Legacy automatic paths written by schema version 1.</summary>
public sealed record SettingsLegacyAutoDefaults(string? InputDir, string? OutputDir);

/// <summary>Settings values plus compatible extension fields and read warnings.</summary>
public sealed record SettingsReadResult(
    SettingsValues Values,
    IReadOnlyDictionary<string, JsonElement> ExtensionFields,
    IReadOnlyList<string> Warnings);

/// <summary>
/// Reads and writes the shared settings.json contract without depending on Avalonia.
/// Compatible extension properties survive a read/write round-trip.
/// </summary>
public sealed class SettingsStore
{
    public const int CurrentSchemaVersion = 2;

    private static readonly string[] CanonicalFieldNames = ["version", "inputDir", "outputDir", "lastPreset", "lastMode"];
    private static readonly JsonSerializerOptions SaveOptions = new() { WriteIndented = true };

    private readonly string _settingsPath;

    public SettingsStore(string? settingsPath = null)
    {
        _settingsPath = Path.GetFullPath(settingsPath is null ? GetDefaultSettingsPath() : RequirePath(settingsPath));
    }

    public string SettingsPath => _settingsPath;

    /// <summary>Resolves the same per-user settings location used by the PowerShell platform module.</summary>
    public static string GetDefaultSettingsPath()
    {
        if (OperatingSystem.IsWindows())
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrWhiteSpace(appData))
            {
                throw new InvalidOperationException("Windows ApplicationData path could not be resolved.");
            }

            return Path.Combine(appData, "media-normalizer", "settings.json");
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrWhiteSpace(home))
        {
            home = Environment.GetEnvironmentVariable("HOME");
        }
        if (string.IsNullOrWhiteSpace(home))
        {
            throw new InvalidOperationException("User home path could not be resolved.");
        }

        if (OperatingSystem.IsMacOS())
        {
            return Path.Combine(home, "Library", "Application Support", "media-normalizer", "settings.json");
        }

        var stateHome = Environment.GetEnvironmentVariable("XDG_STATE_HOME");
        if (string.IsNullOrWhiteSpace(stateHome))
        {
            stateHome = Path.Combine(home, ".local", "state");
        }

        return Path.Combine(stateHome, "media-normalizer", "settings.json");
    }

    public SettingsReadResult Read(
        SettingsValues? defaults = null,
        SettingsLegacyAutoDefaults? legacyAutoDefaults = null)
    {
        var values = defaults ?? SettingsValues.Default;
        var emptyExtensions = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        if (!File.Exists(_settingsPath))
        {
            return new SettingsReadResult(values, emptyExtensions, Array.Empty<string>());
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(File.ReadAllText(_settingsPath, Encoding.UTF8));
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException or SecurityException)
        {
            return WithWarning(values, emptyExtensions,
                $"[WARN ] settings.json の解析に失敗しました。既定値で起動します: {exception.Message}");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !TryFindProperty(root, "version", out var versionElement))
            {
                return WithWarning(values, emptyExtensions, "[WARN ] settings.json に version が無いため既定値で起動します");
            }

            if (!TryParseVersion(versionElement, out var version))
            {
                return WithWarning(values, emptyExtensions, "[WARN ] settings.json の version が不正です。既定値で起動します");
            }

            if (version > CurrentSchemaVersion)
            {
                return WithWarning(values, emptyExtensions,
                    $"[WARN ] settings.json の version={version} は未知のため既定値で起動します");
            }

            var extensions = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var property in root.EnumerateObject())
            {
                if (!IsCanonicalField(property.Name))
                {
                    extensions[property.Name] = property.Value.Clone();
                }
            }

            if (TryFindProperty(root, "inputDir", out var inputElement) && TryGetTruthyString(inputElement, out var inputDir) &&
                !string.IsNullOrWhiteSpace(inputDir))
            {
                values = values with { InputDir = inputDir };
            }
            if (TryFindProperty(root, "outputDir", out var outputElement) && TryGetTruthyString(outputElement, out var outputDir) &&
                !string.IsNullOrWhiteSpace(outputDir))
            {
                values = values with { OutputDir = outputDir };
            }
            if (TryFindProperty(root, "lastPreset", out var presetElement) && TryGetTruthyString(presetElement, out var lastPreset))
            {
                values = values with { LastPreset = lastPreset };
            }
            if (TryFindProperty(root, "lastMode", out var modeElement) && TryGetTruthyString(modeElement, out var lastMode) &&
                new[] { "audio", "video", "both" }.Contains(lastMode, StringComparer.OrdinalIgnoreCase))
            {
                values = values with { LastMode = lastMode };
            }

            if (version < 2 && legacyAutoDefaults is not null)
            {
                if (PathsEqual(values.InputDir, legacyAutoDefaults.InputDir))
                {
                    values = values with { InputDir = defaults?.InputDir ?? SettingsValues.Default.InputDir };
                }
                if (PathsEqual(values.OutputDir, legacyAutoDefaults.OutputDir))
                {
                    values = values with { OutputDir = defaults?.OutputDir ?? SettingsValues.Default.OutputDir };
                }
            }

            return new SettingsReadResult(values, extensions, Array.Empty<string>());
        }
    }

    public void Save(SettingsValues values, IReadOnlyDictionary<string, JsonElement>? extensionFields = null)
    {
        ArgumentNullException.ThrowIfNull(values);

        var payload = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["version"] = CurrentSchemaVersion,
            ["inputDir"] = values.InputDir,
            ["outputDir"] = values.OutputDir,
            ["lastPreset"] = values.LastPreset,
            ["lastMode"] = values.LastMode
        };

        if (extensionFields is not null)
        {
            foreach (var (name, value) in extensionFields)
            {
                if (!string.IsNullOrWhiteSpace(name) && !IsCanonicalField(name))
                {
                    payload[name] = value;
                }
            }
        }

        var directory = Path.GetDirectoryName(_settingsPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        File.WriteAllText(_settingsPath, JsonSerializer.Serialize(payload, SaveOptions), new UTF8Encoding(false));
    }

    private static string RequirePath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        return path;
    }

    private static SettingsReadResult WithWarning(
        SettingsValues values,
        IReadOnlyDictionary<string, JsonElement> extensions,
        string warning) => new(values, extensions, [warning]);

    private static bool IsCanonicalField(string name) =>
        CanonicalFieldNames.Contains(name, StringComparer.OrdinalIgnoreCase);

    private static bool TryFindProperty(JsonElement root, string name, out JsonElement value)
    {
        foreach (var property in root.EnumerateObject())
        {
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }

        value = default;
        return false;
    }

    private static bool TryParseVersion(JsonElement element, out int version)
    {
        var text = element.ValueKind == JsonValueKind.String ? element.GetString() : element.ToString();
        return int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out version);
    }

    private static bool TryGetTruthyString(JsonElement element, out string value)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.String:
                value = element.GetString() ?? string.Empty;
                return value.Length > 0;
            case JsonValueKind.True:
                value = "True";
                return true;
            case JsonValueKind.False:
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                value = string.Empty;
                return false;
            case JsonValueKind.Number:
                value = element.ToString();
                return !element.TryGetDecimal(out var number) || number != decimal.Zero;
            default:
                value = element.ToString();
                return true;
        }
    }

    private static bool PathsEqual(string? left, string? right) =>
        !string.IsNullOrWhiteSpace(right) && string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
}

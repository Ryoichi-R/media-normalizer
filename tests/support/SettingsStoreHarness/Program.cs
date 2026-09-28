using System.Text.Json;
using System.Text.Json.Nodes;
using MediaNormalizer.Gui.Services;

if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: SettingsStoreHarness <repo-root>");
    return 2;
}

var repoRoot = Path.GetFullPath(args[0]);
var fixtureRoot = Path.Combine(repoRoot, "contracts", "fixtures", "settings");
var defaults = new SettingsValues("/Users/default/in", "/Users/default/out", "デフォルト", "audio");

var extensionFixture = Path.Combine(fixtureRoot, "settings-v2-unknown.json");
var extensionStore = new SettingsStore(extensionFixture);
var extensionResult = extensionStore.Read();
Require(extensionResult.Values.InputDir == "/Users/fixtures/input", "Known input path did not load.");
Require(extensionResult.Values.OutputDir == "/Users/fixtures/output", "Known output path did not load.");
Require(extensionResult.Values.LastPreset == "broadcast-custom", "Known preset did not load.");
Require(extensionResult.Values.LastMode == "video", "Known mode did not load.");
Require(extensionResult.ExtensionFields.TryGetValue("extensionState", out var extensionState), "Extension field was not retained.");
Require(extensionState.GetProperty("selectedTab").GetString() == "advanced", "Nested extension property did not load.");

var temporaryRoot = Path.Combine(Path.GetTempPath(), "mn-settings-store-" + Guid.NewGuid().ToString("N"));
try
{
    var roundTripPath = Path.Combine(temporaryRoot, "settings.json");
    var roundTripStore = new SettingsStore(roundTripPath);
    var editedValues = extensionResult.Values with { InputDir = "/Users/fixtures/edited-input" };
    roundTripStore.Save(editedValues, extensionResult.ExtensionFields);
    using var actual = JsonDocument.Parse(await File.ReadAllTextAsync(roundTripPath));
    using var expected = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(fixtureRoot, "settings-save-v2-unknown.json")));
    Require(actual.RootElement.GetProperty("inputDir").GetString() == "/Users/fixtures/edited-input", "Known settings were not updated.");
    Require(JsonEquivalent(actual.RootElement.GetProperty("extensionState"), expected.RootElement.GetProperty("extensionState")),
        "Nested extension field changed during round-trip.");

    var futureResult = new SettingsStore(Path.Combine(fixtureRoot, "settings-v99-future.json")).Read(defaults);
    Require(futureResult.Values == defaults && futureResult.ExtensionFields.Count == 0 && futureResult.Warnings.Count == 1,
        "Future schema fallback did not match the PowerShell contract.");

    var missingVersionResult = new SettingsStore(Path.Combine(fixtureRoot, "settings-missing-version.json")).Read(defaults);
    Require(missingVersionResult.Values == defaults && missingVersionResult.Warnings.Count == 1,
        "Missing schema version fallback did not match the PowerShell contract.");

    var invalidResult = new SettingsStore(Path.Combine(fixtureRoot, "settings-invalid.txt")).Read(defaults);
    Require(invalidResult.Values == defaults && invalidResult.Warnings.Count == 1,
        "Malformed JSON fallback did not match the PowerShell contract.");

    var legacy = new SettingsLegacyAutoDefaults(
        "/Users/fixtures/pre-normalization data",
        "/Users/fixtures/normalization data");
    var legacyResult = new SettingsStore(Path.Combine(fixtureRoot, "settings-v1-legacy.json")).Read(defaults, legacy);
    Require(legacyResult.Values.InputDir == defaults.InputDir, "Legacy automatic input path was not migrated to the default.");
    Require(legacyResult.Values.OutputDir == "/Users/fixtures/custom-output", "Legacy custom output path was not retained.");
    Require(legacyResult.Values.LastMode == "both", "Legacy mode did not load.");

    var missingPath = Path.Combine(temporaryRoot, "missing", "settings.json");
    var missingResult = new SettingsStore(missingPath).Read(defaults);
    Require(missingResult.Values == defaults && missingResult.Warnings.Count == 0,
        "Missing-file defaults did not match the PowerShell contract.");

    var defaultPath = SettingsStore.GetDefaultSettingsPath();
    Require(Path.GetFileName(defaultPath) == "settings.json", "Default settings path has the wrong filename.");

    Console.WriteLine("SettingsStore passed schema v2 extension round-trip, defaults, malformed/future fallback, v1 migration, and default-path checks.");
}
finally
{
    if (Directory.Exists(temporaryRoot))
    {
        Directory.Delete(temporaryRoot, recursive: true);
    }
}

return 0;

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static bool JsonEquivalent(JsonElement left, JsonElement right)
{
    if (left.ValueKind != right.ValueKind)
    {
        return false;
    }

    return left.ValueKind switch
    {
        JsonValueKind.Object => ObjectsEquivalent(left, right),
        JsonValueKind.Array => ArraysEquivalent(left, right),
        JsonValueKind.String => left.GetString() == right.GetString(),
        JsonValueKind.Number => left.GetDecimal() == right.GetDecimal(),
        JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null => left.ToString() == right.ToString(),
        _ => false
    };
}

static bool ObjectsEquivalent(JsonElement left, JsonElement right)
{
    var leftProperties = left.EnumerateObject().ToDictionary(property => property.Name, property => property.Value, StringComparer.Ordinal);
    var rightProperties = right.EnumerateObject().ToDictionary(property => property.Name, property => property.Value, StringComparer.Ordinal);
    return leftProperties.Count == rightProperties.Count && leftProperties.All(pair =>
        rightProperties.TryGetValue(pair.Key, out var rightValue) && JsonEquivalent(pair.Value, rightValue));
}

static bool ArraysEquivalent(JsonElement left, JsonElement right)
{
    var leftItems = left.EnumerateArray().ToArray();
    var rightItems = right.EnumerateArray().ToArray();
    return leftItems.Length == rightItems.Length && leftItems.Zip(rightItems).All(pair => JsonEquivalent(pair.First, pair.Second));
}

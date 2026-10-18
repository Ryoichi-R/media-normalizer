using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace MediaNormalizer.Gui.Services;

public sealed class GuiActivationChannel : IDisposable
{
    private readonly CancellationTokenSource _stop = new();
    private readonly string _pipeName;
    private readonly Guid _instanceId = Guid.NewGuid();
    private readonly Action _activate;
    private readonly Task _listener;
    public GuiActivationChannel(string storageRoot, Action activate)
    {
        _pipeName = GetPipeName(storageRoot) + "-" + _instanceId.ToString("N")[..8];
        var directory = Path.Combine(Path.GetFullPath(storageRoot), "run");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "gui-instance-" + _instanceId.ToString("N") + ".tmp");
        File.WriteAllText(temporary, JsonSerializer.Serialize(new { schemaVersion = 1, instanceId = _instanceId, pipeName = _pipeName }));
        File.Move(temporary, Path.Combine(directory, "gui-instance.json"), true);
        _activate = activate;
        _listener = ListenAsync();
    }
    private static string GetPipeName(string root) => "mn-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root))))[..16];
    private async Task ListenAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(_pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(_stop.Token).ConfigureAwait(false);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(3));
                using var reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true };
                var line = await ReadBoundedLineAsync(reader, timeout.Token).ConfigureAwait(false);
                if (line is null || line.Length > 1024) continue;
                using var request = JsonDocument.Parse(line);
                var json = request.RootElement;
                if (json.EnumerateObject().Count() != 4 || json.GetProperty("schemaVersion").GetInt32() != 1 || json.GetProperty("command").GetString() != "activate" || json.GetProperty("instanceId").GetGuid() != _instanceId || !Guid.TryParse(json.GetProperty("id").GetString(), out var id)) continue;
                _activate();
                await writer.WriteLineAsync(JsonSerializer.Serialize(new { schemaVersion = 1, id, instanceId = _instanceId, status = "activated" }).AsMemory(), timeout.Token).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is IOException or OperationCanceledException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException) { }
        }
    }
    public static async Task<bool> ActivateExistingAsync(string storageRoot, CancellationToken cancellationToken = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            do
            {
                if (await TryActivateAsync(storageRoot, deadline.Token).ConfigureAwait(false)) return true;
                await Task.Delay(50, deadline.Token).ConfigureAwait(false);
            } while (!deadline.IsCancellationRequested);
        }
        catch (OperationCanceledException) { }
        return false;
    }
    private static async Task<bool> TryActivateAsync(string storageRoot, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMilliseconds(500));
        try
        {
            var descriptorPath = Path.Combine(Path.GetFullPath(storageRoot), "run", "gui-instance.json");
            while (!File.Exists(descriptorPath)) await Task.Delay(50, timeout.Token).ConfigureAwait(false);
            using var descriptor = JsonDocument.Parse(await File.ReadAllTextAsync(descriptorPath, timeout.Token).ConfigureAwait(false));
            var instanceId = descriptor.RootElement.GetProperty("instanceId").GetGuid();
            var pipeName = descriptor.RootElement.GetProperty("pipeName").GetString();
            if (descriptor.RootElement.EnumerateObject().Count() != 3 || descriptor.RootElement.GetProperty("schemaVersion").GetInt32() != 1 || pipeName != GetPipeName(storageRoot) + "-" + instanceId.ToString("N")[..8]) return false;
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
            using var reader = new StreamReader(pipe);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true };
            var id = Guid.NewGuid();
            await writer.WriteLineAsync(JsonSerializer.Serialize(new { schemaVersion = 1, command = "activate", id, instanceId }).AsMemory(), timeout.Token).ConfigureAwait(false);
            var line = await ReadBoundedLineAsync(reader, timeout.Token).ConfigureAwait(false);
            if (line is null || line.Length > 1024) return false;
            using var result = JsonDocument.Parse(line);
            return result.RootElement.EnumerateObject().Count() == 4 && result.RootElement.GetProperty("schemaVersion").GetInt32() == 1 && result.RootElement.GetProperty("id").GetGuid() == id && result.RootElement.GetProperty("instanceId").GetGuid() == instanceId && result.RootElement.GetProperty("status").GetString() == "activated";
        }
        catch (Exception exception) when (exception is IOException or OperationCanceledException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException) { return false; }
    }
    private static async Task<string?> ReadBoundedLineAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        var text = new StringBuilder();
        var character = new char[1];
        while (text.Length <= 1024)
        {
            if (await reader.ReadAsync(character.AsMemory(), cancellationToken).ConfigureAwait(false) == 0) return null;
            if (character[0] == '\n') return text.ToString();
            text.Append(character[0]);
        }
        return null;
    }
    public void Dispose()
    {
        _stop.Cancel();
        try { _listener.GetAwaiter().GetResult(); } catch (OperationCanceledException) { }
        _stop.Dispose();
    }
}

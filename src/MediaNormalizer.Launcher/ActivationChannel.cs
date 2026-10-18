using System.Diagnostics;
using System.IO.Pipes;
using System.Text;

namespace MediaNormalizer.Launcher;

internal sealed class ActivationServer : IDisposable
{
    private const int MaximumMessageBytes = 1024;
    private readonly string _pipeName;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly object _stateLock = new();
    private readonly Task _serverTask;
    private readonly NamedPipeServerStream _initialServer;
    private Process? _guiProcess;
    private nint _window;
    private bool _activationPending;
    private bool _terminalFailure;

    private ActivationServer(string pipeName)
    {
        _pipeName = pipeName;
        _initialServer = CreateServer();
        _serverTask = Task.Run(RunAsync);
    }

    internal static ActivationServer? TryStart(string pipeName)
    {
        try
        {
            return new ActivationServer(pipeName);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Debug.WriteLine(exception);
            return null;
        }
    }

    internal void SetGuiProcess(Process process)
    {
        lock (_stateLock) _guiProcess = process;
    }

    internal void SetWindowReady(nint window)
    {
        Process? process;
        bool activate;
        lock (_stateLock)
        {
            _window = window;
            process = _guiProcess;
            activate = _activationPending;
            _activationPending = false;
        }
        if (activate && process is not null) WindowActivator.Activate(process.Id, window);
    }

    internal void SetTerminalFailure()
    {
        lock (_stateLock) _terminalFailure = true;
    }

    private async Task RunAsync()
    {
        NamedPipeServerStream? nextServer = _initialServer;
        while (!_cancellation.IsCancellationRequested)
        {
            try
            {
                await using var pipe = nextServer ?? CreateServer();
                nextServer = null;
                await pipe.WaitForConnectionAsync(_cancellation.Token).ConfigureAwait(false);
                await ServeClientAsync(pipe, _cancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Debug.WriteLine(exception);
                try
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(250), _cancellation.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    private NamedPipeServerStream CreateServer() => new(
        _pipeName,
        PipeDirection.InOut,
        1,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    private async Task ServeClientAsync(Stream pipe, CancellationToken cancellationToken)
    {
        var hello = await ReadMessageAsync(pipe, cancellationToken).ConfigureAwait(false);
        if (!string.Equals(hello, "HELLO", StringComparison.Ordinal))
        {
            await WriteMessageAsync(pipe, "INVALID", cancellationToken).ConfigureAwait(false);
            return;
        }

        Process? process;
        nint window;
        bool failed;
        lock (_stateLock)
        {
            process = _guiProcess;
            window = _window;
            failed = _terminalFailure;
        }
        var state = failed ? "FAILED" : window != 0 ? "READY" : "STARTING";
        await WriteMessageAsync(pipe,
            $"HELLO|{state}|{Environment.ProcessId}|{process?.Id ?? 0}|{window}", cancellationToken).ConfigureAwait(false);

        var command = await ReadMessageAsync(pipe, cancellationToken).ConfigureAwait(false);
        if (!string.Equals(command, "ACTIVATE", StringComparison.Ordinal))
        {
            await WriteMessageAsync(pipe, "INVALID", cancellationToken).ConfigureAwait(false);
            return;
        }

        ActivationResult result;
        lock (_stateLock)
        {
            process = _guiProcess;
            window = _window;
            if (_terminalFailure)
            {
                result = new(ActivationStatus.Invalid);
            }
            else if (window == 0 || process is null)
            {
                _activationPending = true;
                result = new(ActivationStatus.Pending, process?.Id ?? 0, 0);
            }
            else
            {
                result = default;
            }
        }

        if (result == default && process is not null)
            result = WindowActivator.Activate(process.Id, window);

        await WriteMessageAsync(pipe,
            $"RESULT|{result.Status.ToString().ToUpperInvariant()}|{result.ProcessId}|{result.Window}", cancellationToken).ConfigureAwait(false);
    }

    private static async Task<string> ReadMessageAsync(Stream stream, CancellationToken cancellationToken)
    {
        var lengthBuffer = new byte[4];
        await stream.ReadExactlyAsync(lengthBuffer, cancellationToken).ConfigureAwait(false);
        var length = BitConverter.ToInt32(lengthBuffer);
        if (length is <= 0 or > MaximumMessageBytes) throw new InvalidDataException("Invalid activation message length.");
        var buffer = new byte[length];
        await stream.ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
        return Encoding.UTF8.GetString(buffer);
    }

    private static async Task WriteMessageAsync(Stream stream, string message, CancellationToken cancellationToken)
    {
        var buffer = Encoding.UTF8.GetBytes(message);
        if (buffer.Length > MaximumMessageBytes) throw new InvalidDataException("Activation message is too long.");
        await stream.WriteAsync(BitConverter.GetBytes(buffer.Length), cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(buffer, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public void Dispose()
    {
        _cancellation.Cancel();
        try { _serverTask.Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
        _cancellation.Dispose();
    }
}

internal static class ActivationClient
{
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(3);

    internal static ActivationResult RequestActivation(string pipeName)
    {
        try
        {
            using var cancellation = new CancellationTokenSource(OperationTimeout);
            using var pipe = new NamedPipeClientStream(
                ".", pipeName, PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            pipe.ConnectAsync(cancellation.Token).GetAwaiter().GetResult();
            WriteMessage(pipe, "HELLO", cancellation.Token);
            var hello = ReadMessage(pipe, cancellation.Token).Split('|');
            if (hello.Length != 5 || hello[0] != "HELLO" ||
                !int.TryParse(hello[2], out var primaryProcessId))
                return new(ActivationStatus.Invalid);

            NativeMethods.AllowSetForegroundWindow(primaryProcessId);
            WriteMessage(pipe, "ACTIVATE", cancellation.Token);
            var response = ReadMessage(pipe, cancellation.Token).Split('|');
            if (response.Length != 4 || response[0] != "RESULT" ||
                !Enum.TryParse<ActivationStatus>(response[1], true, out var status) ||
                !int.TryParse(response[2], out var guiProcessId) ||
                !nint.TryParse(response[3], out var window))
                return new(ActivationStatus.Invalid);

            var result = new ActivationResult(status, guiProcessId, window);
            if (status == ActivationStatus.Invalid && guiProcessId > 0 && window != 0)
                return WindowActivator.Activate(guiProcessId, window);
            return result;
        }
        catch (Exception exception) when (exception is IOException or TimeoutException or OperationCanceledException)
        {
            Debug.WriteLine(exception);
            return new(ActivationStatus.Unavailable);
        }
    }

    private static string ReadMessage(Stream stream, CancellationToken cancellationToken)
    {
        var lengthBuffer = new byte[4];
        stream.ReadExactlyAsync(lengthBuffer, cancellationToken).AsTask().GetAwaiter().GetResult();
        var length = BitConverter.ToInt32(lengthBuffer);
        if (length is <= 0 or > 1024) throw new InvalidDataException("Invalid activation message length.");
        var buffer = new byte[length];
        stream.ReadExactlyAsync(buffer, cancellationToken).AsTask().GetAwaiter().GetResult();
        return Encoding.UTF8.GetString(buffer);
    }

    private static void WriteMessage(Stream stream, string message, CancellationToken cancellationToken)
    {
        var buffer = Encoding.UTF8.GetBytes(message);
        stream.WriteAsync(BitConverter.GetBytes(buffer.Length), cancellationToken).AsTask().GetAwaiter().GetResult();
        stream.WriteAsync(buffer, cancellationToken).AsTask().GetAwaiter().GetResult();
        stream.FlushAsync(cancellationToken).GetAwaiter().GetResult();
    }
}

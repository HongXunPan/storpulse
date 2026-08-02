using System.Text;
using System.Text.Json;
using StorPulse.Windows.App.Interop;

namespace StorPulse.Windows.App.Services;

internal sealed class WindowsCollectorClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private nint _handle;
    private bool _started;

    public WindowsCollectorClient()
    {
        _handle = WindowsCollectorNative.sp_windows_session_create();
        if (_handle == 0)
        {
            throw new CollectorClientException(
                "client",
                "session_create_failed",
                null);
        }
    }

    public void Start(string runId)
    {
        ObjectDisposedException.ThrowIf(_handle == 0, this);
        var bytes = Encoding.UTF8.GetBytes(runId);
        var status = WindowsCollectorNative.sp_windows_session_start(
            _handle,
            bytes,
            (nuint)bytes.Length);
        if (status != WindowsCollectorNative.StatusOk)
        {
            throw ReadFailure(status);
        }

        _started = true;
    }

    public string NextSnapshotJson()
    {
        EnsureStarted();
        var buffer = WindowsCollectorNative.sp_windows_session_next_snapshot_json(_handle);
        return ReadBuffer(buffer);
    }

    public CollectorStopResult Stop()
    {
        EnsureStarted();
        var buffer = WindowsCollectorNative.sp_windows_session_stop_json(_handle);
        try
        {
            if (buffer.Status != WindowsCollectorNative.StatusOk)
            {
                throw ReadFailure(buffer.Status);
            }

            var result = JsonSerializer.Deserialize<CollectorStopResult>(
                buffer.CopyUtf8(),
                JsonOptions);
            return result
                ?? throw new CollectorClientException("protocol", "invalid_stop_result", null);
        }
        catch (JsonException)
        {
            throw new CollectorClientException("protocol", "invalid_stop_result", null);
        }
        finally
        {
            _started = false;
            WindowsCollectorNative.sp_windows_buffer_free(buffer);
        }
    }

    public void Dispose()
    {
        var handle = Interlocked.Exchange(ref _handle, 0);
        if (handle != 0)
        {
            WindowsCollectorNative.sp_windows_session_destroy(handle);
        }

        _started = false;
    }

    private string ReadBuffer(NativeJsonBuffer buffer)
    {
        try
        {
            if (buffer.Status != WindowsCollectorNative.StatusOk)
            {
                throw ReadFailure(buffer.Status);
            }

            return buffer.CopyUtf8();
        }
        finally
        {
            WindowsCollectorNative.sp_windows_buffer_free(buffer);
        }
    }

    private CollectorClientException ReadFailure(int status)
    {
        var buffer = WindowsCollectorNative.sp_windows_session_last_error_json(_handle);
        try
        {
            if (buffer.Status == WindowsCollectorNative.StatusOk
                && buffer.Pointer != 0
                && buffer.Length > 0)
            {
                var envelope = JsonSerializer.Deserialize<CollectorFailureEnvelope>(
                    buffer.CopyUtf8(),
                    JsonOptions);
                if (envelope?.Failure is { } failure)
                {
                    return new CollectorClientException(
                        failure.Phase,
                        failure.SafeErrorCode,
                        failure.NativeCode);
                }
            }
        }
        catch (JsonException)
        {
            // 错误响应无效时只返回稳定状态码，不传播原始内容。
        }
        finally
        {
            WindowsCollectorNative.sp_windows_buffer_free(buffer);
        }

        return new CollectorClientException("client", $"native_status_{status}", null);
    }

    private void EnsureStarted()
    {
        ObjectDisposedException.ThrowIf(_handle == 0, this);
        if (!_started)
        {
            throw new InvalidOperationException("Windows 采集会话尚未开始。");
        }
    }
}

internal sealed class CollectorClientException(
    string phase,
    string safeErrorCode,
    uint? nativeCode)
    : Exception($"Windows 采集失败：{phase}/{safeErrorCode}/{nativeCode?.ToString() ?? "none"}")
{
    public string Phase { get; } = phase;

    public string SafeErrorCode { get; } = safeErrorCode;

    public uint? NativeCode { get; } = nativeCode;

    public bool IsRestricted => SafeErrorCode == "standard_user_required"
        || (SafeErrorCode is "open_service_failed" or "service_start_failed"
            && NativeCode is 5 or 1060);
}

internal sealed class CollectorStopResult
{
    public int SchemaVersion { get; init; }

    public ulong? FinalSequence { get; init; }

    public JsonElement[] FinalSnapshots { get; init; } = [];

    public bool ServiceStopped { get; init; }

    public uint ServiceWin32ExitCode { get; init; }

    public uint ServiceSpecificExitCode { get; init; }
}

internal sealed class CollectorFailureEnvelope
{
    public CollectorFailure? Failure { get; init; }
}

internal sealed class CollectorFailure
{
    public string Phase { get; init; } = "unknown";

    public string SafeErrorCode { get; init; } = "unknown";

    public uint? NativeCode { get; init; }
}

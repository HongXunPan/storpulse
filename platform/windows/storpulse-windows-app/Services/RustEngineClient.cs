using System.Text;
using System.Text.Json;
using StorPulse.Windows.App.Interop;
using StorPulse.Windows.App.Models;

namespace StorPulse.Windows.App.Services;

internal sealed class RustEngineClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private nint _handle;

    public RustEngineClient()
    {
        _handle = RustEngineNative.sp_engine_create();
        if (_handle == 0)
        {
            throw new EngineClientException("共享引擎句柄创建失败。");
        }
    }

    public RawSnapshotMetadata IngestRawSnapshot(string json)
    {
        ObjectDisposedException.ThrowIf(_handle == 0, this);
        RawSnapshotMetadata metadata;
        try
        {
            metadata = JsonSerializer.Deserialize<RawSnapshotMetadata>(json, JsonOptions)
                ?? throw new EngineClientException("原始快照元数据为空。");
        }
        catch (JsonException)
        {
            throw new EngineClientException("原始快照 JSON 无法解析。");
        }
        if (metadata.MonotonicNanoseconds == 0)
        {
            throw new EngineClientException("原始快照缺少有效单调时间。");
        }

        var bytes = Encoding.UTF8.GetBytes(json);
        var status = RustEngineNative.sp_engine_ingest_json(
            _handle,
            bytes,
            (nuint)bytes.Length);
        if (status != RustEngineNative.StatusOk)
        {
            throw ReadFailure(status);
        }

        return metadata;
    }

    public RealtimeSnapshotData Snapshot(ulong monotonicNanoseconds)
    {
        ObjectDisposedException.ThrowIf(_handle == 0, this);
        var buffer = RustEngineNative.sp_engine_snapshot_json(
            _handle,
            monotonicNanoseconds);
        try
        {
            if (buffer.Status != RustEngineNative.StatusOk)
            {
                throw ReadFailure(buffer.Status);
            }

            return JsonSerializer.Deserialize<RealtimeSnapshotData>(
                    buffer.CopyUtf8(),
                    JsonOptions)
                ?? throw new EngineClientException("共享引擎返回了空快照。");
        }
        catch (JsonException)
        {
            throw new EngineClientException("共享引擎快照 JSON 无法解析。");
        }
        finally
        {
            RustEngineNative.sp_buffer_free(buffer);
        }
    }

    public void Dispose()
    {
        var handle = Interlocked.Exchange(ref _handle, 0);
        if (handle != 0)
        {
            RustEngineNative.sp_engine_destroy(handle);
        }
    }

    private EngineClientException ReadFailure(int status)
    {
        var buffer = RustEngineNative.sp_engine_last_error_json(_handle);
        try
        {
            if (buffer.Status == RustEngineNative.StatusOk
                && buffer.Pointer != 0
                && buffer.Length > 0)
            {
                var error = JsonSerializer.Deserialize<EngineError>(
                    buffer.CopyUtf8(),
                    JsonOptions);
                if (!string.IsNullOrWhiteSpace(error?.Message))
                {
                    return new EngineClientException(
                        $"共享引擎拒绝请求（{status}）：{error.Message}");
                }
            }
        }
        catch (JsonException)
        {
            // 错误响应无效时只返回稳定状态码。
        }
        finally
        {
            RustEngineNative.sp_buffer_free(buffer);
        }

        return new EngineClientException($"共享引擎拒绝请求（{status}）。");
    }
}

internal sealed class EngineClientException(string message) : Exception(message);

internal sealed class EngineError
{
    public string Message { get; init; } = string.Empty;
}

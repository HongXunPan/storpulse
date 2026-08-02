using Microsoft.UI.Dispatching;
using StorPulse.Windows.App.Diagnostics;
using StorPulse.Windows.App.Models;
using StorPulse.Windows.App.ViewModels;

namespace StorPulse.Windows.App.Services;

internal sealed class WindowsRealtimeMonitor
{
    private readonly RealtimeShellViewModel _viewModel;
    private readonly DispatcherQueue _dispatcherQueue;
    private CancellationTokenSource? _cancellation;
    private Task? _samplingTask;

    public WindowsRealtimeMonitor(
        RealtimeShellViewModel viewModel,
        DispatcherQueue dispatcherQueue)
    {
        _viewModel = viewModel;
        _dispatcherQueue = dispatcherQueue;
    }

    public void Start()
    {
        if (_samplingTask is not null)
        {
            return;
        }

        _cancellation = new CancellationTokenSource();
        _samplingTask = Task.Run(() => RunAsync(_cancellation.Token));
    }

    public async Task StopAsync()
    {
        var task = _samplingTask;
        if (task is null)
        {
            return;
        }

        _cancellation?.Cancel();
        await task.ConfigureAwait(false);
        _cancellation?.Dispose();
        _cancellation = null;
        _samplingTask = null;
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        WindowsCollectorClient? collector = null;
        RustEngineClient? engine = null;
        var collectorStarted = false;
        try
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            collector = new WindowsCollectorClient();
            engine = new RustEngineClient();
            var runId = $"stage2c_{DateTimeOffset.UtcNow:yyyyMMddHHmmss}_{Environment.ProcessId}";
            collector.Start(runId);
            collectorStarted = true;
            ShellGateConsoleReporter.Stage("windows_realtime_collection_started");

            while (!cancellationToken.IsCancellationRequested)
            {
                var rawJson = collector.NextSnapshotJson();
                var metadata = engine.IngestRawSnapshot(rawJson);
                var snapshot = engine.Snapshot(metadata.MonotonicNanoseconds);
                await DispatchAsync(() => _viewModel.ApplySnapshot(snapshot));
            }
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure("windows_realtime_collection", exception);
            var presentation = FailurePresentation.From(exception);
            await DispatchAsync(() => _viewModel.ShowFailure(
                presentation.Title,
                presentation.Message,
                presentation.Restricted));
        }
        finally
        {
            try
            {
                if (collectorStarted && collector is not null && engine is not null)
                {
                    await StopCollectorAsync(collector, engine);
                }
            }
            finally
            {
                engine?.Dispose();
                collector?.Dispose();
            }
        }
    }

    private async Task StopCollectorAsync(
        WindowsCollectorClient collector,
        RustEngineClient engine)
    {
        try
        {
            var result = collector.Stop();
            RealtimeSnapshotData? finalSnapshot = null;
            foreach (var rawSnapshot in result.FinalSnapshots)
            {
                var metadata = engine.IngestRawSnapshot(rawSnapshot.GetRawText());
                finalSnapshot = engine.Snapshot(metadata.MonotonicNanoseconds);
            }

            if (finalSnapshot is not null)
            {
                await DispatchAsync(() => _viewModel.ApplySnapshot(finalSnapshot));
            }

            ShellGateConsoleReporter.Stage("windows_realtime_collection_stopped");
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure("windows_realtime_shutdown", exception);
            var presentation = FailurePresentation.From(exception);
            await DispatchAsync(() => _viewModel.ShowFailure(
                "采集清理失败",
                presentation.Message,
                false));
        }
    }

    private Task DispatchAsync(Action action)
    {
        if (_dispatcherQueue.HasThreadAccess)
        {
            action();
            return Task.CompletedTask;
        }

        var completion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_dispatcherQueue.TryEnqueue(() =>
            {
                try
                {
                    action();
                    completion.SetResult(true);
                }
                catch (Exception exception)
                {
                    completion.SetException(exception);
                }
            }))
        {
            completion.SetException(
                new InvalidOperationException("无法把实时采集结果发送到界面线程。"));
        }

        return completion.Task;
    }
}

internal sealed record FailurePresentation(
    string Title,
    string Message,
    bool Restricted)
{
    public static FailurePresentation From(Exception exception)
    {
        if (exception is CollectorClientException collector)
        {
            return FromCollector(collector);
        }

        if (exception is DllNotFoundException or EntryPointNotFoundException
            or BadImageFormatException)
        {
            return new(
                "原生组件不可用",
                "当前产物缺少匹配的 x64 客户端或共享引擎 DLL，请重新下载完整阶段 2C artifact。",
                false);
        }

        if (exception is EngineClientException)
        {
            return new(
                "共享引擎不可用",
                "原始快照未能进入共享聚合引擎；界面不会回退到模拟数据。",
                false);
        }

        return new(
            "实时采集失败",
            "采集链路发生未分类错误；请保留控制台阶段字段并退出 StorPulse。",
            false);
    }

    private static FailurePresentation FromCollector(CollectorClientException exception)
    {
        var message = exception.SafeErrorCode switch
        {
            "open_service_failed" when exception.NativeCode == 1060
                => "本机尚未安装 StorPulse 按需服务，请先运行 artifact 中的管理员安装入口。",
            "open_service_failed" or "service_start_failed" when exception.NativeCode == 5
                => "当前标准用户没有启动 StorPulse 按需服务的权限，请用管理员入口重新安装服务。",
            "standard_user_required"
                => "WinUI 必须以标准用户运行；请关闭管理员终端后从普通终端重新启动。",
            _ => $"采集阶段 {exception.Phase} 返回稳定错误码 {exception.SafeErrorCode}"
                + (exception.NativeCode is null ? "。" : $"（{exception.NativeCode}）。"),
        };
        return new(
            exception.IsRestricted ? "Windows 采集能力受限" : "Windows 采集服务失败",
            message,
            exception.IsRestricted);
    }
}

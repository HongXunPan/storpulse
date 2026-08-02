using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using StorPulse.Windows.App.Diagnostics;
using StorPulse.Windows.App.Interop;

namespace StorPulse.Windows.App.Lifecycle;

internal sealed class WindowLifecycleController : IDisposable
{
    private readonly Window _window;
    private readonly AppWindow _appWindow;
    private readonly nint _windowHandle;
    private readonly NotificationAreaController _notificationArea;
    private bool _exitRequested;
    private bool _disposed;

    public WindowLifecycleController(Window window)
    {
        _window = window ?? throw new ArgumentNullException(nameof(window));
        _windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var windowId = Win32Interop.GetWindowIdFromWindow(_windowHandle);
        _appWindow = AppWindow.GetFromWindowId(windowId)
            ?? throw new InvalidOperationException("无法取得 WinUI 主窗口对应的 AppWindow。");
        _appWindow.Closing += AppWindow_Closing;
        _notificationArea = new NotificationAreaController(
            _windowHandle,
            QueueShowMainWindow,
            QueueExitApplication);
    }

    public void ShowMainWindow()
    {
        if (_disposed)
        {
            return;
        }

        _appWindow.Show();
        NativeMethods.SetForegroundWindow(_windowHandle);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _appWindow.Closing -= AppWindow_Closing;
        _notificationArea.Dispose();
    }

    private void AppWindow_Closing(
        AppWindow sender,
        AppWindowClosingEventArgs args)
    {
        if (_exitRequested)
        {
            return;
        }

        args.Cancel = true;
        sender.Hide();
        ShellGateConsoleReporter.Stage("window_hidden_to_notification_area");
    }

    private void QueueShowMainWindow()
    {
        if (!_window.DispatcherQueue.TryEnqueue(() =>
            {
                ShellGateConsoleReporter.Stage("notification_area_window_show_started");
                ShowMainWindow();
                ShellGateConsoleReporter.Stage("notification_area_window_show_completed");
            }))
        {
            ReportDispatcherFailure("notification_area_show_dispatch");
        }
    }

    private void QueueExitApplication()
    {
        if (!_window.DispatcherQueue.TryEnqueue(RequestExit))
        {
            ReportDispatcherFailure("notification_area_exit_dispatch");
        }
    }

    private void RequestExit()
    {
        if (_exitRequested)
        {
            return;
        }

        _exitRequested = true;
        ShellGateConsoleReporter.Stage("application_exit_requested");
        Dispose();
        _window.Close();
    }

    private static void ReportDispatcherFailure(string source)
    {
        ShellGateConsoleReporter.Failure(
            source,
            new InvalidOperationException("无法把通知区域操作发送到界面线程。"));
    }
}

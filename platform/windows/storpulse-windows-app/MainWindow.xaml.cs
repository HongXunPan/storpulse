using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using StorPulse.Windows.App.Diagnostics;
using StorPulse.Windows.App.Services;
using StorPulse.Windows.App.ViewModels;
using Windows.Graphics;

namespace StorPulse.Windows.App;

public sealed partial class MainWindow : Window
{
    private readonly WindowsRealtimeMonitor _monitor;

    public MainWindow()
    {
        ShellGateConsoleReporter.Stage("main_window_model_started");
        ViewModel = new RealtimeShellViewModel();
        ShellGateConsoleReporter.Stage("main_window_model_completed");
        ShellGateConsoleReporter.Stage("main_window_xaml_initialize_started");
        InitializeComponent();
        ShellGateConsoleReporter.Stage("main_window_xaml_initialize_completed");
        Title = "StorPulse · Windows 阶段 2C 实时采集门禁";
        ShellGateConsoleReporter.Stage("window_resize_started");
        ResizeForGate();
        ShellGateConsoleReporter.Stage("window_resize_completed");

        _monitor = new WindowsRealtimeMonitor(ViewModel, DispatcherQueue);
        Closed += MainWindow_Closed;
    }

    public RealtimeShellViewModel ViewModel { get; }

    public void StartCollection()
    {
        _monitor.Start();
    }

    public Task StopCollectionAsync()
    {
        return _monitor.StopAsync();
    }

    private void ResizeForGate()
    {
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        AppWindow.GetFromWindowId(windowId)?.Resize(new SizeInt32(1180, 760));
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        ShellGateConsoleReporter.Stage("window_closed");
        Closed -= MainWindow_Closed;
    }

    private void SortName_Click(object sender, RoutedEventArgs args)
    {
        ViewModel.SortBy(ApplicationSortKey.Name);
    }

    private void SortRead_Click(object sender, RoutedEventArgs args)
    {
        ViewModel.SortBy(ApplicationSortKey.ReadRate);
    }

    private void SortWrite_Click(object sender, RoutedEventArgs args)
    {
        ViewModel.SortBy(ApplicationSortKey.WriteRate);
    }

    private void SortTotal_Click(object sender, RoutedEventArgs args)
    {
        ViewModel.SortBy(ApplicationSortKey.Total);
    }
}

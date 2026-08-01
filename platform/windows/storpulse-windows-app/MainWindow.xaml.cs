using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using StorPulse.Windows.App.ViewModels;
using Windows.Graphics;

namespace StorPulse.Windows.App;

public sealed partial class MainWindow : Window
{
    private readonly DispatcherTimer _refreshTimer;

    public MainWindow()
    {
        ViewModel = new RealtimeShellViewModel();
        InitializeComponent();
        Title = "StorPulse · Windows 阶段 2A 界面门禁";
        ResizeForGate();

        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1),
        };
        _refreshTimer.Tick += RefreshTimer_Tick;
        Closed += MainWindow_Closed;
        _refreshTimer.Start();
    }

    public RealtimeShellViewModel ViewModel { get; }

    private void ResizeForGate()
    {
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        AppWindow.GetFromWindowId(windowId)?.Resize(new SizeInt32(1180, 760));
    }

    private void RefreshTimer_Tick(object? sender, object e)
    {
        ViewModel.Advance();
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        _refreshTimer.Stop();
        _refreshTimer.Tick -= RefreshTimer_Tick;
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

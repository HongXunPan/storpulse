using Microsoft.UI.Xaml;
using StorPulse.Windows.App.Diagnostics;
using StorPulse.Windows.App.Lifecycle;

namespace StorPulse.Windows.App;

public partial class App : Application
{
    private MainWindow? _window;
    private WindowLifecycleController? _windowLifecycle;

    public App()
    {
        UnhandledException += App_UnhandledException;
        ShellGateConsoleReporter.Stage("app_xaml_initialize_started");
        try
        {
            InitializeComponent();
            ShellGateConsoleReporter.Stage("app_xaml_initialize_completed");
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure("app_constructor", exception);
            throw;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        ShellGateConsoleReporter.Stage("app_launch_entered");
        try
        {
            ShellGateConsoleReporter.Stage("main_window_construction_started");
            var window = new MainWindow();
            _window = window;
            ShellGateConsoleReporter.Stage("main_window_construction_completed");
            ShellGateConsoleReporter.Stage("window_lifecycle_construction_started");
            _windowLifecycle = new WindowLifecycleController(
                window,
                window.StopCollectionAsync);
            ShellGateConsoleReporter.Stage("window_lifecycle_construction_completed");
            ActivationRouter.Register(HandleRedirectedActivation);
            window.StartCollection();
            ShellGateConsoleReporter.Stage("window_activation_started");
            _windowLifecycle.ShowMainWindow();
            ShellGateConsoleReporter.Stage("window_activation_completed");
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure("app_launch", exception);
            throw;
        }
    }

    private void HandleRedirectedActivation()
    {
        var dispatcher = _window?.DispatcherQueue;
        if (dispatcher is null || !dispatcher.TryEnqueue(() =>
            {
                ShellGateConsoleReporter.Stage("redirected_activation_window_show_started");
                _windowLifecycle?.ShowMainWindow();
                ShellGateConsoleReporter.Stage("redirected_activation_window_show_completed");
            }))
        {
            ShellGateConsoleReporter.Failure(
                "redirected_activation_dispatch",
                new InvalidOperationException("无法把单实例唤起请求发送到界面线程。"));
        }
    }

    private void App_UnhandledException(
        object sender,
        Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        ShellGateConsoleReporter.Failure(
            "xaml_unhandled_exception",
            args.Exception,
            args.Message);
    }
}

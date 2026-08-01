using Microsoft.UI.Xaml;
using StorPulse.Windows.App.Diagnostics;

namespace StorPulse.Windows.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        ShellGateConsoleReporter.Initialize();
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
            _window = new MainWindow();
            ShellGateConsoleReporter.Stage("main_window_construction_completed");
            ShellGateConsoleReporter.Stage("window_activation_started");
            _window.Activate();
            ShellGateConsoleReporter.Stage("window_activation_completed");
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure("app_launch", exception);
            throw;
        }
    }

    private void App_UnhandledException(
        object sender,
        Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        ShellGateConsoleReporter.Failure("xaml_unhandled_exception", args.Exception);
    }
}

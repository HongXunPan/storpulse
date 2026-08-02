using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using StorPulse.Windows.App.Diagnostics;
using StorPulse.Windows.App.Interop;
using StorPulse.Windows.App.Lifecycle;

namespace StorPulse.Windows.App;

internal static class Program
{
    private const string MainInstanceKey = "StorPulse.Windows.App.Main";

    [STAThread]
    public static async Task Main(string[] args)
    {
        ShellGateConsoleReporter.Initialize();
        try
        {
            await RunAsync();
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure("program_main", exception);
            throw;
        }
    }

    private static async Task RunAsync()
    {
        ShellGateConsoleReporter.Stage("single_instance_registration_started");
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var activationArguments = AppInstance.GetCurrent().GetActivatedEventArgs();
        var mainInstance = AppInstance.FindOrRegisterForKey(MainInstanceKey);
        if (!mainInstance.IsCurrent)
        {
            ShellGateConsoleReporter.Stage("single_instance_redirect_started");
            if (!NativeMethods.AllowSetForegroundWindow(mainInstance.ProcessId))
            {
                ShellGateConsoleReporter.Stage("single_instance_foreground_handoff_unavailable");
            }

            await mainInstance.RedirectActivationToAsync(activationArguments);
            ShellGateConsoleReporter.Stage("single_instance_redirect_completed");
            return;
        }

        mainInstance.Activated += MainInstance_Activated;
        try
        {
            ShellGateConsoleReporter.Stage("single_instance_primary_ready");
            Application.Start(initialization =>
            {
                var context = new DispatcherQueueSynchronizationContext(
                    DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(context);
                _ = new App();
            });
        }
        finally
        {
            mainInstance.Activated -= MainInstance_Activated;
        }
    }

    private static void MainInstance_Activated(
        object? sender,
        AppActivationArguments args)
    {
        ShellGateConsoleReporter.Stage("single_instance_activation_received");
        ActivationRouter.RequestMainWindowActivation();
    }
}

using System.Runtime.InteropServices;

namespace StorPulse.Windows.App.Diagnostics;

internal static class ShellGateConsoleReporter
{
    private const string EnabledEnvironmentVariable = "STORPULSE_SHELL_GATE_CONSOLE";
    private const uint AttachParentProcess = uint.MaxValue;
    private const int ErrorAccessDenied = 5;

    private static bool _enabled;
    private static string _currentStage = "not_started";

    public static void Initialize()
    {
        if (!string.Equals(
                Environment.GetEnvironmentVariable(EnabledEnvironmentVariable),
                "1",
                StringComparison.Ordinal))
        {
            return;
        }

        try
        {
            var attached = AttachConsole(AttachParentProcess);
            if (!attached && Marshal.GetLastWin32Error() != ErrorAccessDenied)
            {
                return;
            }

            var writer = TextWriter.Synchronized(
                new StreamWriter(Console.OpenStandardOutput())
                {
                    AutoFlush = true,
                });
            Console.SetOut(writer);
            Console.SetError(writer);
            _enabled = true;
            Stage("diagnostics_console_ready");
        }
        catch
        {
            _enabled = false;
        }
    }

    public static void Stage(string stage)
    {
        _currentStage = stage;
        if (_enabled)
        {
            Console.WriteLine($"stage={stage}");
        }
    }

    public static void Failure(string source, Exception exception)
    {
        if (!_enabled)
        {
            return;
        }

        var exceptionType = exception.GetType().FullName ?? exception.GetType().Name;
        Console.Error.WriteLine($"failure_source={source}");
        Console.Error.WriteLine($"failure_stage={_currentStage}");
        Console.Error.WriteLine($"exception_type={exceptionType}");
        Console.Error.WriteLine($"hresult=0x{unchecked((uint)exception.HResult):X8}");
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}

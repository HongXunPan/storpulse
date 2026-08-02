using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace StorPulse.Windows.App.Diagnostics;

internal static partial class ShellGateConsoleReporter
{
    private const string EnabledEnvironmentVariable = "STORPULSE_SHELL_GATE_CONSOLE";
    private const uint AttachParentProcess = uint.MaxValue;
    private const int ErrorAccessDenied = 5;
    private const int MaxExceptionMessageLength = 512;
    private const int MaxInnerExceptionDepth = 3;

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

            var encoding = new UTF8Encoding(false);
            Console.OutputEncoding = encoding;
            var writer = TextWriter.Synchronized(
                new StreamWriter(Console.OpenStandardOutput(), encoding)
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

    public static void Failure(
        string source,
        Exception exception,
        string? frameworkMessage = null)
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
        WriteNativeErrorCode("native_error_code", exception);

        try
        {
            WriteMessageDetails("exception", exception.Message);

            if (!string.IsNullOrWhiteSpace(frameworkMessage)
                && !string.Equals(frameworkMessage, exception.Message, StringComparison.Ordinal))
            {
                WriteMessageDetails("framework", frameworkMessage);
            }

            var innerException = exception.InnerException;
            for (var depth = 1;
                 depth <= MaxInnerExceptionDepth && innerException is not null;
                 depth++)
            {
                var prefix = $"inner_exception_{depth}";
                var innerType = innerException.GetType().FullName
                    ?? innerException.GetType().Name;
                Console.Error.WriteLine($"{prefix}_type={innerType}");
                Console.Error.WriteLine(
                    $"{prefix}_hresult=0x{unchecked((uint)innerException.HResult):X8}");
                WriteNativeErrorCode($"{prefix}_native_error_code", innerException);
                WriteMessageDetails(prefix, innerException.Message);
                innerException = innerException.InnerException;
            }
        }
        catch
        {
            Console.Error.WriteLine("diagnostic_detail_status=unavailable");
        }
    }

    private static void WriteNativeErrorCode(string fieldName, Exception exception)
    {
        if (exception is Win32Exception win32Exception)
        {
            Console.Error.WriteLine($"{fieldName}={win32Exception.NativeErrorCode}");
        }
    }

    private static void WriteMessageDetails(string prefix, string message)
    {
        var location = XamlLocationRegex().Match(message);
        if (location.Success)
        {
            Console.Error.WriteLine($"{prefix}_xaml_line={location.Groups["line"].Value}");
            Console.Error.WriteLine(
                $"{prefix}_xaml_position={location.Groups["position"].Value}");
        }

        Console.Error.WriteLine($"{prefix}_message={SanitizeMessage(message)}");
    }

    private static string SanitizeMessage(string message)
    {
        var normalized = WhitespaceRegex().Replace(message, " ").Trim();
        if (normalized.Length == 0)
        {
            return "unavailable";
        }

        if (SensitiveContentRegex().IsMatch(normalized))
        {
            return "redacted_sensitive_content";
        }

        normalized = GuidRegex().Replace(normalized, "<guid>");
        normalized = EmailRegex().Replace(normalized, "<email>");
        return normalized.Length <= MaxExceptionMessageLength
            ? normalized
            : $"{normalized[..MaxExceptionMessageLength]}...";
    }

    [GeneratedRegex(
        @"\[\s*Line:\s*(?<line>\d+)\s+Position:\s*(?<position>\d+)\s*\]",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex XamlLocationRegex();

    [GeneratedRegex(
        @"(?:[A-Za-z]:\\|\\\\|/Users/|/home/|\bS-\d-\d+(?:-\d+)+\b)",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex SensitiveContentRegex();

    [GeneratedRegex(
        @"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex GuidRegex();

    [GeneratedRegex(@"\b[^\s@]+@[^\s@]+\b", RegexOptions.CultureInvariant)]
    private static partial Regex EmailRegex();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespaceRegex();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}

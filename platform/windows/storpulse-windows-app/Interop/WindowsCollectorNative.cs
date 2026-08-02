using System.Runtime.InteropServices;

namespace StorPulse.Windows.App.Interop;

internal static class WindowsCollectorNative
{
    internal const int StatusOk = 0;

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern nint sp_windows_session_create();

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void sp_windows_session_destroy(nint handle);

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int sp_windows_session_start(
        nint handle,
        byte[] runId,
        nuint length);

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern NativeJsonBuffer sp_windows_session_next_snapshot_json(nint handle);

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern NativeJsonBuffer sp_windows_session_stop_json(nint handle);

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern NativeJsonBuffer sp_windows_session_last_error_json(nint handle);

    [DllImport(
        "storpulse_windows_client.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void sp_windows_buffer_free(NativeJsonBuffer buffer);
}

using System.Runtime.InteropServices;

namespace StorPulse.Windows.App.Interop;

internal static class RustEngineNative
{
    internal const int StatusOk = 0;

    [DllImport(
        "storpulse_ffi.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern nint sp_engine_create();

    [DllImport(
        "storpulse_ffi.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void sp_engine_destroy(nint engine);

    [DllImport(
        "storpulse_ffi.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int sp_engine_ingest_json(
        nint engine,
        byte[] json,
        nuint length);

    [DllImport(
        "storpulse_ffi.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern NativeJsonBuffer sp_engine_snapshot_json(
        nint engine,
        ulong monotonicNanoseconds);

    [DllImport(
        "storpulse_ffi.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern NativeJsonBuffer sp_engine_last_error_json(nint engine);

    [DllImport(
        "storpulse_ffi.dll",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void sp_buffer_free(NativeJsonBuffer buffer);
}

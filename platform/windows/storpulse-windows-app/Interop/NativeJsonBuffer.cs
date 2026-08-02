using System.Runtime.InteropServices;
using System.Text;

namespace StorPulse.Windows.App.Interop;

[StructLayout(LayoutKind.Sequential)]
internal struct NativeJsonBuffer
{
    public nint Pointer;
    public nuint Length;
    public nuint Capacity;
    public int Status;

    public string CopyUtf8()
    {
        if (Pointer == 0 || Length == 0)
        {
            throw new InvalidOperationException("原生组件返回了空 JSON 缓冲区。");
        }

        var length = checked((int)Length);
        var bytes = new byte[length];
        Marshal.Copy(Pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }
}

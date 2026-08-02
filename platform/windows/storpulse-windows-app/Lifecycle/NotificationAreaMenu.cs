using System.ComponentModel;
using System.Runtime.InteropServices;
using StorPulse.Windows.App.Interop;

namespace StorPulse.Windows.App.Lifecycle;

internal enum NotificationAreaCommand
{
    None,
    Open,
    Exit,
}

internal sealed class NotificationAreaMenu
{
    private const uint MenuFlagString = 0x0000;
    private const uint MenuFlagSeparator = 0x0800;
    private const uint TrackMenuRightButton = 0x0002;
    private const uint TrackMenuReturnCommand = 0x0100;
    private const uint TrackMenuNoNotify = 0x0080;
    private const uint WindowMessageNull = 0x0000;
    private const uint OpenCommand = 1001;
    private const uint ExitCommand = 1002;

    private readonly nint _windowHandle;

    public NotificationAreaMenu(nint windowHandle)
    {
        _windowHandle = windowHandle;
    }

    public NotificationAreaCommand Show(NativeMethods.Point point)
    {
        var menuHandle = NativeMethods.CreatePopupMenu();
        if (menuHandle == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            AppendMenuItem(menuHandle, OpenCommand, "打开 StorPulse");
            if (!NativeMethods.AppendMenu(menuHandle, MenuFlagSeparator, 0, null))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            AppendMenuItem(menuHandle, ExitCommand, "退出 StorPulse");
            NativeMethods.SetForegroundWindow(_windowHandle);
            var command = NativeMethods.TrackPopupMenuEx(
                menuHandle,
                TrackMenuRightButton | TrackMenuReturnCommand | TrackMenuNoNotify,
                point.X,
                point.Y,
                _windowHandle,
                0);
            NativeMethods.PostMessage(
                _windowHandle,
                WindowMessageNull,
                0,
                0);
            return command switch
            {
                OpenCommand => NotificationAreaCommand.Open,
                ExitCommand => NotificationAreaCommand.Exit,
                _ => NotificationAreaCommand.None,
            };
        }
        finally
        {
            NativeMethods.DestroyMenu(menuHandle);
        }
    }

    private static void AppendMenuItem(
        nint menuHandle,
        uint command,
        string text)
    {
        if (!NativeMethods.AppendMenu(menuHandle, MenuFlagString, command, text))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}

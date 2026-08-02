using System.ComponentModel;
using System.Runtime.InteropServices;
using StorPulse.Windows.App.Diagnostics;
using StorPulse.Windows.App.Interop;

namespace StorPulse.Windows.App.Lifecycle;

internal sealed class NotificationAreaController : IDisposable
{
    private const uint NotifyIconAdd = 0;
    private const uint NotifyIconDelete = 2;
    private const uint NotifyIconSetFocus = 3;
    private const uint NotifyIconSetVersion = 4;
    private const uint NotifyIconFlagMessage = 0x00000001;
    private const uint NotifyIconFlagIcon = 0x00000002;
    private const uint NotifyIconFlagTip = 0x00000004;
    private const uint NotifyIconFlagGuid = 0x00000020;
    private const uint NotifyIconVersion4 = 4;
    private const uint NotificationCallbackMessage = 0x8000 + 0x51;
    private const uint WindowMessageContextMenu = 0x007B;
    private const uint WindowMessageLeftButtonDoubleClick = 0x0203;
    private const uint NotifyIconSelect = 0x0400;
    private const uint NotifyIconKeySelect = 0x0401;
    private const int DefaultApplicationIcon = 32512;
    private static readonly nuint WindowSubclassId = 0x53504E41;

    private static readonly Guid NotificationIconGuid = new(
        "1FD245C0-D513-4B9C-A5E4-9D46C2DFD155");

    private readonly nint _windowHandle;
    private readonly Action _showWindow;
    private readonly Action _exitApplication;
    private readonly NativeMethods.SubclassProcedure _subclassProcedure;
    private readonly NotificationAreaMenu _menu;
    private readonly uint _taskbarCreatedMessage;
    private NativeMethods.NotifyIconData _iconData;
    private bool _iconAdded;
    private bool _disposed;

    public NotificationAreaController(
        nint windowHandle,
        Action showWindow,
        Action exitApplication)
    {
        if (windowHandle == 0)
        {
            throw new ArgumentException("通知区域控制器需要有效窗口句柄。", nameof(windowHandle));
        }

        _windowHandle = windowHandle;
        _showWindow = showWindow ?? throw new ArgumentNullException(nameof(showWindow));
        _exitApplication = exitApplication ?? throw new ArgumentNullException(nameof(exitApplication));
        _subclassProcedure = WindowSubclassProcedure;
        _menu = new NotificationAreaMenu(windowHandle);
        _taskbarCreatedMessage = NativeMethods.RegisterWindowMessage("TaskbarCreated");
        if (_taskbarCreatedMessage == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        if (!NativeMethods.SetWindowSubclass(
                _windowHandle,
                _subclassProcedure,
                WindowSubclassId,
                0))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            AddIcon();
        }
        catch
        {
            NativeMethods.RemoveWindowSubclass(
                _windowHandle,
                _subclassProcedure,
                WindowSubclassId);
            throw;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        DeleteIcon();
        NativeMethods.RemoveWindowSubclass(
            _windowHandle,
            _subclassProcedure,
            WindowSubclassId);
    }

    private void AddIcon()
    {
        var iconHandle = NativeMethods.LoadIcon(0, (nint)DefaultApplicationIcon);
        if (iconHandle == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        _iconData = new NativeMethods.NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.NotifyIconData>(),
            WindowHandle = _windowHandle,
            IconId = 1,
            Flags = NotifyIconFlagMessage
                | NotifyIconFlagIcon
                | NotifyIconFlagTip
                | NotifyIconFlagGuid,
            CallbackMessage = NotificationCallbackMessage,
            IconHandle = iconHandle,
            ToolTip = "StorPulse 阶段 2B 生命周期门禁",
            Info = string.Empty,
            InfoTitle = string.Empty,
            ItemGuid = NotificationIconGuid,
        };

        if (!NativeMethods.ShellNotifyIcon(NotifyIconAdd, ref _iconData))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        _iconAdded = true;
        _iconData.TimeoutOrVersion = NotifyIconVersion4;
        if (!NativeMethods.ShellNotifyIcon(NotifyIconSetVersion, ref _iconData))
        {
            DeleteIcon();
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        ShellGateConsoleReporter.Stage("notification_area_icon_added");
    }

    private void DeleteIcon()
    {
        if (!_iconAdded)
        {
            return;
        }

        NativeMethods.ShellNotifyIcon(NotifyIconDelete, ref _iconData);
        _iconAdded = false;
        ShellGateConsoleReporter.Stage("notification_area_icon_removed");
    }

    private nint WindowSubclassProcedure(
        nint windowHandle,
        uint message,
        nuint wordParameter,
        nint longParameter,
        nuint subclassId,
        nuint referenceData)
    {
        try
        {
            if (message == _taskbarCreatedMessage)
            {
                _iconAdded = false;
                AddIcon();
                return 0;
            }

            if (message == NotificationCallbackMessage)
            {
                HandleNotification(wordParameter, longParameter);
                return 0;
            }
        }
        catch (Exception exception)
        {
            ShellGateConsoleReporter.Failure(
                "notification_area_message",
                exception);
        }

        return NativeMethods.DefSubclassProc(
            windowHandle,
            message,
            wordParameter,
            longParameter);
    }

    private void HandleNotification(nuint wordParameter, nint longParameter)
    {
        var notification = unchecked((uint)longParameter.ToInt64()) & 0xFFFF;
        switch (notification)
        {
            case WindowMessageContextMenu:
                ShowContextMenu(wordParameter);
                break;
            case NotifyIconSelect:
            case NotifyIconKeySelect:
            case WindowMessageLeftButtonDoubleClick:
                _showWindow();
                break;
        }
    }

    private void ShowContextMenu(nuint wordParameter)
    {
        var command = _menu.Show(ResolveMenuPoint(wordParameter));
        switch (command)
        {
            case NotificationAreaCommand.Open:
                _showWindow();
                break;
            case NotificationAreaCommand.Exit:
                _exitApplication();
                break;
        }

        NativeMethods.ShellNotifyIcon(NotifyIconSetFocus, ref _iconData);
    }

    private static NativeMethods.Point ResolveMenuPoint(nuint wordParameter)
    {
        var packed = unchecked((long)wordParameter);
        var point = new NativeMethods.Point
        {
            X = unchecked((short)(packed & 0xFFFF)),
            Y = unchecked((short)((packed >> 16) & 0xFFFF)),
        };
        if ((point.X != -1 || point.Y != -1)
            || NativeMethods.GetCursorPos(out point))
        {
            return point;
        }

        throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}

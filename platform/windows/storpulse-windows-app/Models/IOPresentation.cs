namespace StorPulse.Windows.App.Models;

internal static class IOPresentation
{
    public static string Rate(double? bytesPerSecond)
    {
        if (bytesPerSecond is null)
        {
            return "不可用";
        }

        var value = bytesPerSecond.Value;
        return value switch
        {
            < 1024 => $"{value:0} B/s",
            < 1024 * 1024 => $"{value / 1024:0.0} KiB/s",
            < 1024 * 1024 * 1024 => $"{value / (1024 * 1024):0.0} MiB/s",
            _ => $"{value / (1024 * 1024 * 1024):0.00} GiB/s",
        };
    }

    public static string Bytes(ulong bytes)
    {
        return bytes switch
        {
            < 1024 => $"{bytes} B",
            < 1024UL * 1024 => $"{bytes / 1024d:0.0} KiB",
            < 1024UL * 1024 * 1024 => $"{bytes / (1024d * 1024):0.0} MiB",
            _ => $"{bytes / (1024d * 1024 * 1024):0.00} GiB",
        };
    }

    public static string Duration(ulong milliseconds)
    {
        var duration = TimeSpan.FromMilliseconds(milliseconds);
        return duration.TotalHours >= 1
            ? $"{(int)duration.TotalHours}:{duration.Minutes:00}:{duration.Seconds:00}"
            : $"{duration.Minutes}:{duration.Seconds:00}";
    }
}

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml.Controls;
using StorPulse.Windows.App.Models;

namespace StorPulse.Windows.App.ViewModels;

public enum ApplicationSortKey
{
    Name,
    ReadRate,
    WriteRate,
    Total,
}

public sealed class RealtimeShellViewModel : INotifyPropertyChanged
{
    private readonly Dictionary<string, RealtimeApplicationRow> _rowsById =
        new(StringComparer.Ordinal);
    private RealtimeApplicationRow? _selectedRow;
    private string _statusText = "正在连接按需采集服务";
    private string _informationTitle = "阶段 2C 正在启动";
    private string _informationMessage = "等待标准用户客户端连接本机采集服务。";
    private InfoBarSeverity _informationSeverity = InfoBarSeverity.Informational;
    private ApplicationSortKey _sortKey = ApplicationSortKey.ReadRate;
    private bool _sortDescending = true;
    private ulong _refreshCount;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<RealtimeApplicationRow> Rows { get; } = [];

    public string RowCountText => $"{Rows.Count:N0} 个应用";

    public string SortText => $"排序：{SortName(_sortKey)} {(_sortDescending ? "降序" : "升序")}";

    public string StatusText
    {
        get => _statusText;
        private set => SetField(ref _statusText, value);
    }

    public string InformationTitle
    {
        get => _informationTitle;
        private set => SetField(ref _informationTitle, value);
    }

    public string InformationMessage
    {
        get => _informationMessage;
        private set => SetField(ref _informationMessage, value);
    }

    public InfoBarSeverity InformationSeverity
    {
        get => _informationSeverity;
        private set => SetField(ref _informationSeverity, value);
    }

    public RealtimeApplicationRow? SelectedRow
    {
        get => _selectedRow;
        set => SetField(ref _selectedRow, value);
    }

    internal void ApplySnapshot(RealtimeSnapshotData snapshot)
    {
        var activeIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var application in snapshot.Applications)
        {
            if (string.IsNullOrWhiteSpace(application.ApplicationId)
                || !activeIds.Add(application.ApplicationId))
            {
                continue;
            }

            if (!_rowsById.TryGetValue(application.ApplicationId, out var row))
            {
                row = new RealtimeApplicationRow(application);
                _rowsById.Add(row.Id, row);
                Rows.Add(row);
            }
            else
            {
                row.Apply(application);
            }
        }

        foreach (var removedId in _rowsById.Keys.Where(id => !activeIds.Contains(id)).ToArray())
        {
            var removed = _rowsById[removedId];
            Rows.Remove(removed);
            _rowsById.Remove(removedId);
            if (ReferenceEquals(SelectedRow, removed))
            {
                SelectedRow = null;
            }
        }

        ApplySortOrder();
        _refreshCount++;
        var deviceRates = snapshot.Devices
            .Where(device => device.Current is not null)
            .Select(device => device.Current!)
            .ToArray();
        double? deviceReadRate = deviceRates.Length == 0
            ? null
            : deviceRates.Sum(rate => rate.ReadBytesPerSecond);
        double? deviceWriteRate = deviceRates.Length == 0
            ? null
            : deviceRates.Sum(rate => rate.WriteBytesPerSecond);
        var restricted = snapshot.Summary.RestrictedProcesses;
        StatusText = $"第 {_refreshCount:N0} 次实时刷新 · "
            + $"{snapshot.Summary.ReadableProcesses:N0} 个可读进程 · "
            + $"{restricted:N0} 个受限进程 · "
            + $"{snapshot.Summary.DeviceCount:N0} 个设备";
        InformationTitle = snapshot.Freshness == "fresh"
            ? "Windows ETW 实时采集中"
            : "Windows 实时数据已过期";
        InformationMessage = $"来源：{DisplaySource(snapshot.MetricSource)}；"
            + $"完整性：{DisplayCompleteness(snapshot.Completeness)}。"
            + $"设备当前读取 {IOPresentation.Rate(deviceReadRate)}，"
            + $"写入 {IOPresentation.Rate(deviceWriteRate)}；"
            + $"未归因事件 {snapshot.Summary.UnmappedDiskEvents:N0}，"
            + $"事件丢失 {snapshot.Summary.EventsLost:N0}，"
            + $"缓冲区丢失 {snapshot.Summary.BuffersLost:N0}。"
            + "关闭窗口后仍在通知区域采集，显式退出会停止协议与服务。";
        InformationSeverity = snapshot.Freshness == "fresh"
            && snapshot.Completeness == "complete"
                ? InfoBarSeverity.Success
                : InfoBarSeverity.Warning;
        OnPropertyChanged(nameof(RowCountText));
    }

    internal void ShowFailure(string title, string message, bool restricted)
    {
        InformationTitle = title;
        InformationMessage = message;
        InformationSeverity = restricted
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Error;
        StatusText = restricted ? "采集能力受限" : "实时采集失败";
    }

    public void SortBy(ApplicationSortKey key)
    {
        if (_sortKey == key)
        {
            _sortDescending = !_sortDescending;
        }
        else
        {
            _sortKey = key;
            _sortDescending = key != ApplicationSortKey.Name;
        }

        ApplySortOrder();
        OnPropertyChanged(nameof(SortText));
    }

    private void ApplySortOrder()
    {
        var sorted = SortRows(Rows, _sortKey, _sortDescending).ToArray();
        for (var targetIndex = 0; targetIndex < sorted.Length; targetIndex++)
        {
            var currentIndex = Rows.IndexOf(sorted[targetIndex]);
            if (currentIndex != targetIndex)
            {
                Rows.Move(currentIndex, targetIndex);
            }
        }
    }

    private static IEnumerable<RealtimeApplicationRow> SortRows(
        IEnumerable<RealtimeApplicationRow> rows,
        ApplicationSortKey key,
        bool descending)
    {
        Func<RealtimeApplicationRow, object> selector = key switch
        {
            ApplicationSortKey.Name => row => row.DisplayName,
            ApplicationSortKey.ReadRate => row => row.ReadBytesPerSecond ?? -1d,
            ApplicationSortKey.WriteRate => row => row.WriteBytesPerSecond ?? -1d,
            ApplicationSortKey.Total => row => row.TotalBytes,
            _ => row => row.DisplayName,
        };

        return descending
            ? rows.OrderByDescending(selector).ThenBy(row => row.Id, StringComparer.Ordinal)
            : rows.OrderBy(selector).ThenBy(row => row.Id, StringComparer.Ordinal);
    }

    private static string SortName(ApplicationSortKey key)
    {
        return key switch
        {
            ApplicationSortKey.Name => "应用",
            ApplicationSortKey.ReadRate => "当前读取",
            ApplicationSortKey.WriteRate => "当前写入",
            ApplicationSortKey.Total => "本次累计",
            _ => "应用",
        };
    }

    private static string DisplaySource(string source)
    {
        return string.IsNullOrWhiteSpace(source) ? "未知" : source;
    }

    private static string DisplayCompleteness(string completeness)
    {
        return completeness switch
        {
            "complete" => "完整",
            "partial" => "部分可用",
            "restricted" => "受限",
            _ => "未知",
        };
    }

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }

        field = value;
        OnPropertyChanged(propertyName);
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

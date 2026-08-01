using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using StorPulse.Windows.App.Models;
using StorPulse.Windows.App.Services;

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
    private readonly ShellGateSnapshotSource _source = new();
    private readonly Dictionary<string, RealtimeApplicationRow> _rowsById;
    private RealtimeApplicationRow? _selectedRow;
    private string _statusText = "等待首次局部刷新";
    private ApplicationSortKey _sortKey = ApplicationSortKey.Name;
    private bool _sortDescending;
    private ulong _refreshCount;

    public RealtimeShellViewModel()
    {
        var rows = _source.CreateInitialSnapshot()
            .Select(sample => new RealtimeApplicationRow(sample))
            .ToArray();
        _rowsById = rows.ToDictionary(row => row.Id, StringComparer.Ordinal);
        Rows = new ObservableCollection<RealtimeApplicationRow>(rows);
        SortBy(ApplicationSortKey.ReadRate);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<RealtimeApplicationRow> Rows { get; }

    public string RowCountText => $"{Rows.Count:N0} 行内存门禁数据";

    public string SortText => $"排序：{SortName(_sortKey)} {(_sortDescending ? "降序" : "升序")}";

    public string StatusText
    {
        get => _statusText;
        private set
        {
            if (_statusText == value)
            {
                return;
            }

            _statusText = value;
            OnPropertyChanged();
        }
    }

    public RealtimeApplicationRow? SelectedRow
    {
        get => _selectedRow;
        set
        {
            if (ReferenceEquals(_selectedRow, value))
            {
                return;
            }

            _selectedRow = value;
            OnPropertyChanged();
        }
    }

    public void Advance()
    {
        var updates = _source.Advance();
        foreach (var update in updates)
        {
            _rowsById[update.Id].Apply(update);
        }

        _refreshCount++;
        StatusText = $"第 {_refreshCount:N0} 次刷新 · 本次仅更新 {updates.Count} 行 · 未产生磁盘写入";
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

        var selectedId = SelectedRow?.Id;
        var sorted = SortRows(Rows, _sortKey, _sortDescending).ToArray();
        Rows.Clear();
        foreach (var row in sorted)
        {
            Rows.Add(row);
        }

        SelectedRow = selectedId is null ? null : _rowsById[selectedId];
        OnPropertyChanged(nameof(SortText));
    }

    private static IEnumerable<RealtimeApplicationRow> SortRows(
        IEnumerable<RealtimeApplicationRow> rows,
        ApplicationSortKey key,
        bool descending)
    {
        Func<RealtimeApplicationRow, object> selector = key switch
        {
            ApplicationSortKey.Name => row => row.DisplayName,
            ApplicationSortKey.ReadRate => row => row.ReadBytesPerSecond,
            ApplicationSortKey.WriteRate => row => row.WriteBytesPerSecond,
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

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace StorPulse.Windows.App.Models;

public sealed class RealtimeApplicationRow : INotifyPropertyChanged
{
    private string _displayName = string.Empty;
    private string _processSummary = string.Empty;
    private double? _readBytesPerSecond;
    private double? _writeBytesPerSecond;
    private ulong _readBytes;
    private ulong _writeBytes;
    private ulong _durationMilliseconds;

    internal RealtimeApplicationRow(RealtimeApplicationData sample)
    {
        Id = sample.ApplicationId;
        Apply(sample);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id { get; }

    public string DisplayName => _displayName;

    public string ProcessSummary => _processSummary;

    public double? ReadBytesPerSecond => _readBytesPerSecond;

    public double? WriteBytesPerSecond => _writeBytesPerSecond;

    public ulong TotalBytes => ulong.MaxValue - _readBytes < _writeBytes
        ? ulong.MaxValue
        : _readBytes + _writeBytes;

    public string ReadRateText => IOPresentation.Rate(_readBytesPerSecond);

    public string WriteRateText => IOPresentation.Rate(_writeBytesPerSecond);

    public string TotalText => $"读 {IOPresentation.Bytes(_readBytes)} · 写 {IOPresentation.Bytes(_writeBytes)}";

    public string DurationText => IOPresentation.Duration(_durationMilliseconds);

    internal void Apply(RealtimeApplicationData sample)
    {
        _displayName = string.IsNullOrWhiteSpace(sample.DisplayName)
            ? sample.ApplicationId
            : sample.DisplayName;
        _processSummary = sample.HelperCount == 0
            ? $"{sample.ProcessCount:N0} 个进程"
            : $"{sample.ProcessCount:N0} 个进程 · {sample.HelperCount:N0} 个 Helper";
        _readBytesPerSecond = sample.Current?.ReadBytesPerSecond;
        _writeBytesPerSecond = sample.Current?.WriteBytesPerSecond;
        _readBytes = sample.RunReadBytes;
        _writeBytes = sample.RunWriteBytes;
        _durationMilliseconds = sample.ContinuousIoDurationMilliseconds;
        OnPropertyChanged(nameof(DisplayName));
        OnPropertyChanged(nameof(ProcessSummary));
        NotifyMetricsChanged();
    }

    private void NotifyMetricsChanged()
    {
        OnPropertyChanged(nameof(ReadBytesPerSecond));
        OnPropertyChanged(nameof(WriteBytesPerSecond));
        OnPropertyChanged(nameof(TotalBytes));
        OnPropertyChanged(nameof(ReadRateText));
        OnPropertyChanged(nameof(WriteRateText));
        OnPropertyChanged(nameof(TotalText));
        OnPropertyChanged(nameof(DurationText));
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

using System.ComponentModel;
using System.Runtime.CompilerServices;
using StorPulse.Windows.App.Services;

namespace StorPulse.Windows.App.Models;

public sealed class RealtimeApplicationRow : INotifyPropertyChanged
{
    private double _readBytesPerSecond;
    private double _writeBytesPerSecond;
    private ulong _readBytes;
    private ulong _writeBytes;
    private ulong _durationMilliseconds;

    internal RealtimeApplicationRow(ShellGateRowSample sample)
    {
        Id = sample.Id;
        DisplayName = sample.DisplayName;
        ProcessSummary = sample.ProcessSummary;
        Apply(sample);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id { get; }

    public string DisplayName { get; }

    public string ProcessSummary { get; }

    public double ReadBytesPerSecond => _readBytesPerSecond;

    public double WriteBytesPerSecond => _writeBytesPerSecond;

    public ulong TotalBytes => _readBytes + _writeBytes;

    public string ReadRateText => IOPresentation.Rate(_readBytesPerSecond);

    public string WriteRateText => IOPresentation.Rate(_writeBytesPerSecond);

    public string TotalText => $"读 {IOPresentation.Bytes(_readBytes)} · 写 {IOPresentation.Bytes(_writeBytes)}";

    public string DurationText => IOPresentation.Duration(_durationMilliseconds);

    internal void Apply(ShellGateRowSample sample)
    {
        _readBytesPerSecond = sample.ReadBytesPerSecond;
        _writeBytesPerSecond = sample.WriteBytesPerSecond;
        _readBytes = sample.ReadBytes;
        _writeBytes = sample.WriteBytes;
        _durationMilliseconds = sample.DurationMilliseconds;
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

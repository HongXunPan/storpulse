namespace StorPulse.Windows.App.Services;

internal sealed record ShellGateRowSample(
    string Id,
    string DisplayName,
    string ProcessSummary,
    double ReadBytesPerSecond,
    double WriteBytesPerSecond,
    ulong ReadBytes,
    ulong WriteBytes,
    ulong DurationMilliseconds);

internal sealed class ShellGateSnapshotSource
{
    public const int RowCount = 1000;
    public const int RefreshBatchSize = 32;

    private readonly ulong[] _readBytes = new ulong[RowCount];
    private readonly ulong[] _writeBytes = new ulong[RowCount];
    private readonly ulong[] _durationMilliseconds = new ulong[RowCount];
    private ulong _tick;

    public IReadOnlyList<ShellGateRowSample> CreateInitialSnapshot()
    {
        var rows = new ShellGateRowSample[RowCount];
        for (var index = 0; index < RowCount; index++)
        {
            _readBytes[index] = (ulong)(index + 1) * 256 * 1024;
            _writeBytes[index] = (ulong)(index + 1) * 96 * 1024;
            _durationMilliseconds[index] = (ulong)(index % 180) * 1000;
            rows[index] = CreateSample(index);
        }

        return rows;
    }

    public IReadOnlyList<ShellGateRowSample> Advance()
    {
        _tick++;
        var rows = new ShellGateRowSample[RefreshBatchSize];
        var firstIndex = (int)((_tick * RefreshBatchSize) % RowCount);
        for (var offset = 0; offset < RefreshBatchSize; offset++)
        {
            var index = (firstIndex + offset) % RowCount;
            var readIncrement = (ulong)((index % 17) + 1) * 64 * 1024;
            var writeIncrement = (ulong)((index % 11) + 1) * 24 * 1024;
            _readBytes[index] += readIncrement;
            _writeBytes[index] += writeIncrement;
            _durationMilliseconds[index] += 1000;
            rows[offset] = CreateSample(index);
        }

        return rows;
    }

    private ShellGateRowSample CreateSample(int index)
    {
        var readRate = (((ulong)index * 53UL) + (_tick * 97UL)) % 8192UL * 1024d;
        var writeRate = (((ulong)index * 31UL) + (_tick * 61UL)) % 4096UL * 1024d;
        var processCount = (index % 5) + 1;
        var helperCount = index % 4;
        var processSummary = helperCount == 0
            ? $"{processCount} 个进程"
            : $"{processCount} 个进程 · {helperCount} 个 Helper";

        return new ShellGateRowSample(
            $"shell-gate:{index + 1:D4}",
            $"门禁进程 {index + 1:D4}",
            processSummary,
            readRate,
            writeRate,
            _readBytes[index],
            _writeBytes[index],
            _durationMilliseconds[index]);
    }
}

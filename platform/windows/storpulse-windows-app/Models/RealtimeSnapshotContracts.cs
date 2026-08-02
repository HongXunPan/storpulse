namespace StorPulse.Windows.App.Models;

internal sealed class RawSnapshotMetadata
{
    public ulong MonotonicNanoseconds { get; init; }
}

internal sealed class RealtimeSnapshotData
{
    public int SchemaVersion { get; init; }

    public string CapturedAt { get; init; } = string.Empty;

    public ulong MonotonicNanoseconds { get; init; }

    public string MetricSource { get; init; } = string.Empty;

    public string[] MetricScope { get; init; } = [];

    public string Freshness { get; init; } = "unknown";

    public string Completeness { get; init; } = "restricted";

    public RealtimeDeviceData[] Devices { get; init; } = [];

    public RealtimeApplicationData[] Applications { get; init; } = [];

    public RealtimeSummaryData Summary { get; init; } = new();
}

internal sealed class RealtimeDeviceData
{
    public string DeviceId { get; init; } = string.Empty;

    public RealtimeRateData? Current { get; init; }

    public ulong RunReadBytes { get; init; }

    public ulong RunWriteBytes { get; init; }
}

internal sealed class RealtimeApplicationData
{
    public string ApplicationId { get; init; } = string.Empty;

    public string DisplayName { get; init; } = string.Empty;

    public int ProcessCount { get; init; }

    public int HelperCount { get; init; }

    public RealtimeRateData? Current { get; init; }

    public ulong RunReadBytes { get; init; }

    public ulong RunWriteBytes { get; init; }

    public ulong ContinuousIoDurationMilliseconds { get; init; }
}

internal sealed class RealtimeRateData
{
    public double ReadBytesPerSecond { get; init; }

    public double WriteBytesPerSecond { get; init; }
}

internal sealed class RealtimeSummaryData
{
    public int DiscoveredProcesses { get; init; }

    public int ReadableProcesses { get; init; }

    public int RestrictedProcesses { get; init; }

    public int ExitedProcesses { get; init; }

    public int DeviceCount { get; init; }

    public string LastSuccessfulSampleAt { get; init; } = string.Empty;

    public ulong UnmappedDiskEvents { get; init; }

    public ulong EventsLost { get; init; }

    public ulong BuffersLost { get; init; }
}

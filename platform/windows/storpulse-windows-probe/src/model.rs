use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeIoCounters {
    pub read_operations: u64,
    pub write_operations: u64,
    pub other_operations: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub other_bytes: u64,
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessMeasurements {
    pub process_id: u32,
    pub start_time_ticks: u64,
    pub kernel_time_ticks: u64,
    pub user_time_ticks: u64,
    pub working_set_bytes: u64,
    pub private_bytes: u64,
    pub io: NativeIoCounters,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessScanReport {
    pub discovered_processes: u32,
    pub readable_processes: u32,
    pub restricted_processes: u32,
    pub exited_processes: u32,
    pub other_failures: u32,
    pub broad_io_read_bytes: u64,
    pub broad_io_write_bytes: u64,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfMeasurementReport {
    pub idle_read_delta_bytes: u64,
    pub idle_write_delta_bytes: u64,
    pub workload_read_delta_bytes: u64,
    pub workload_write_delta_bytes: u64,
    pub cpu_time_delta_ticks: u64,
    pub working_set_bytes: u64,
    pub private_bytes: u64,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkloadReport {
    pub attempted: bool,
    pub completed: bool,
    pub sequential_write_bytes: u64,
    pub sequential_read_bytes: u64,
    pub sequential_read_mode: Option<&'static str>,
    pub logical_sector_bytes: Option<u32>,
    pub physical_sector_bytes: Option<u32>,
    pub small_files_created: u32,
    pub short_lived_processes_started: u32,
    pub cleanup_succeeded: bool,
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EtwEventReport {
    pub session_started: bool,
    pub consumer_started: bool,
    pub start_status: u32,
    pub open_status: u32,
    pub process_status: u32,
    pub stop_status: u32,
    pub total_events: u64,
    pub disk_events: u64,
    pub disk_read_events: u64,
    pub disk_write_events: u64,
    pub disk_read_bytes: u64,
    pub disk_write_bytes: u64,
    pub mapped_disk_events: u64,
    pub unmapped_disk_events: u64,
    pub short_payload_events: u64,
    pub thread_events: u64,
    pub process_events: u64,
    pub events_lost: u32,
    pub log_buffers_lost: u32,
    pub realtime_buffers_lost: u32,
    pub events_by_opcode: BTreeMap<u8, u64>,
    pub top_processes: Vec<ProcessDiskIoReport>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessDiskIoReport {
    pub process_id: u32,
    pub is_probe: bool,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub read_events: u64,
    pub write_events: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeEnvironment {
    pub architecture: &'static str,
    pub process_id: u32,
    pub elevated: Option<bool>,
    pub performance_log_user: Option<bool>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticError {
    pub phase: &'static str,
    pub api: &'static str,
    pub code: u32,
    pub category: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineEvent {
    pub elapsed_milliseconds: u128,
    pub level: &'static str,
    pub phase: &'static str,
    pub event: &'static str,
    pub code: Option<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stage0Report {
    pub schema_version: u32,
    pub generated_at_unix_milliseconds: u128,
    pub evidence_level: &'static str,
    pub metric_source: &'static str,
    pub outcome: &'static str,
    pub environment: ProbeEnvironment,
    pub process_scan_before: ProcessScanReport,
    pub process_scan_after: ProcessScanReport,
    pub self_measurements: SelfMeasurementReport,
    pub etw: EtwEventReport,
    pub workload: WorkloadReport,
    pub errors: Vec<DiagnosticError>,
    pub limitations: Vec<&'static str>,
}

pub fn delta(before: u64, after: u64) -> u64 {
    after.saturating_sub(before)
}

use serde::{Deserialize, Serialize};

use super::{Completeness, Freshness, MetricScope, ProcessIdentity};

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IoRate {
    pub read_bytes_per_second: f64,
    pub write_bytes_per_second: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeProcess {
    pub identity: ProcessIdentity,
    pub parent_pid: Option<i32>,
    pub executable_name: String,
    pub application_id: String,
    pub application_name: String,
    pub is_helper: bool,
    pub launched_by_application_id: Option<String>,
    pub current: Option<IoRate>,
    pub average_last_minute: Option<IoRate>,
    pub run_read_bytes: u64,
    pub run_write_bytes: u64,
    pub continuous_io_duration_milliseconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub physical_footprint_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeApplication {
    pub application_id: String,
    pub display_name: String,
    pub process_count: usize,
    pub helper_count: usize,
    pub current: Option<IoRate>,
    pub average_last_minute: Option<IoRate>,
    pub run_read_bytes: u64,
    pub run_write_bytes: u64,
    pub continuous_io_duration_milliseconds: u64,
    pub process_identities: Vec<ProcessIdentity>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeDevice {
    pub device_id: String,
    pub current: Option<IoRate>,
    pub run_read_bytes: u64,
    pub run_write_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeSummary {
    pub discovered_processes: usize,
    pub readable_processes: usize,
    pub restricted_processes: usize,
    pub exited_processes: usize,
    #[serde(default)]
    pub device_count: usize,
    pub collection_duration_nanoseconds: u64,
    pub last_successful_sample_at: String,
    #[serde(default)]
    pub unmapped_disk_events: u64,
    #[serde(default)]
    pub events_lost: u64,
    #[serde(default)]
    pub buffers_lost: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeSnapshot {
    pub schema_version: u32,
    pub captured_at: String,
    pub monotonic_nanoseconds: u64,
    pub metric_source: String,
    pub metric_scope: Vec<MetricScope>,
    pub freshness: Freshness,
    pub completeness: Completeness,
    pub devices: Vec<RealtimeDevice>,
    pub applications: Vec<RealtimeApplication>,
    pub processes: Vec<RealtimeProcess>,
    pub summary: RealtimeSummary,
    pub active_observation_session: Option<ObservationSessionProgress>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservationSessionProgress {
    pub session_id: String,
    pub started_at: String,
    pub duration_milliseconds: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub peak_read_bytes_per_second: f64,
    pub peak_write_bytes_per_second: f64,
}

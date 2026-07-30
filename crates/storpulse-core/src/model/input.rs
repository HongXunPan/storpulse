use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricScope {
    Device,
    StorageProcess,
    GeneralProcessIo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Freshness {
    Fresh,
    Stale,
    Paused,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Completeness {
    Complete,
    Partial,
    Restricted,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessIdentity {
    pub pid: i32,
    pub start_time_ticks: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessIoSample {
    pub identity: ProcessIdentity,
    #[serde(default)]
    pub parent_pid: Option<i32>,
    pub executable_name: String,
    #[serde(default)]
    pub application_id: Option<String>,
    #[serde(default)]
    pub application_name: Option<String>,
    #[serde(default)]
    pub is_helper: bool,
    #[serde(default)]
    pub launched_by_application_id: Option<String>,
    pub read_bytes: u64,
    pub write_bytes: u64,
    #[serde(default)]
    pub user_time_nanoseconds: u64,
    #[serde(default)]
    pub system_time_nanoseconds: u64,
    #[serde(default)]
    pub resident_bytes: u64,
    #[serde(default)]
    pub physical_footprint_bytes: u64,
}

impl ProcessIoSample {
    pub fn normalized_application_id(&self) -> String {
        self.application_id
            .clone()
            .unwrap_or_else(|| format!("executable:{}", self.executable_name.to_lowercase()))
    }

    pub fn display_name(&self) -> String {
        self.application_name
            .clone()
            .unwrap_or_else(|| self.executable_name.clone())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceIoSample {
    pub registry_entry_id: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    #[serde(default)]
    pub read_operations: Option<u64>,
    #[serde(default)]
    pub write_operations: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionSummary {
    pub discovered_processes: usize,
    pub readable_processes: usize,
    pub restricted_processes: usize,
    pub exited_processes: usize,
    pub device_count: usize,
    pub collection_duration_nanoseconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawSnapshot {
    pub schema_version: u32,
    pub captured_at: String,
    pub monotonic_nanoseconds: u64,
    pub metric_source: String,
    pub metric_scope: Vec<MetricScope>,
    pub freshness: Freshness,
    pub completeness: Completeness,
    pub processes: Vec<ProcessIoSample>,
    pub devices: Vec<DeviceIoSample>,
    pub summary: CollectionSummary,
}

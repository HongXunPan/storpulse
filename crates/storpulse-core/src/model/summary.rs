use serde::{Deserialize, Serialize};

use super::{Completeness, IoRate};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationContribution {
    pub application_id: String,
    pub display_name: String,
    pub read_bytes: u64,
    pub write_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservationSession {
    pub session_id: String,
    pub started_at: String,
    pub ended_at: String,
    pub duration_milliseconds: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub peak: IoRate,
    pub top_applications: Vec<ApplicationContribution>,
    pub completeness: Completeness,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySummary {
    pub application_id: String,
    pub display_name: String,
    pub started_at: String,
    pub ended_at: String,
    pub duration_milliseconds: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub peak: IoRate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MinuteBucket {
    pub bucket_started_at: String,
    pub application_id: Option<String>,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub peak: IoRate,
    pub completeness: Completeness,
}

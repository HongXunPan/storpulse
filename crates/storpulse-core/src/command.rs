use std::{
    error::Error,
    fmt::{Display, Formatter},
};

use serde::{Deserialize, Serialize};

use crate::{
    ActivityPolicy,
    model::{ActivitySummary, ObservationSession},
};

#[derive(Debug, Clone)]
pub struct EngineConfig {
    pub stale_after_nanoseconds: u64,
    pub history_window_nanoseconds: u64,
    pub maximum_history_points: usize,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            stale_after_nanoseconds: 3_000_000_000,
            history_window_nanoseconds: 60_000_000_000,
            maximum_history_points: 120,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum EngineCommand {
    StartObservation {
        session_id: String,
        started_at: String,
        monotonic_nanoseconds: u64,
    },
    StopObservation {
        ended_at: String,
        monotonic_nanoseconds: u64,
    },
    ConfigureActivity {
        policy: ActivityPolicy,
    },
    DrainCompletedActivities,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineCommandResult {
    Accepted,
    ObservationStopped { session: ObservationSession },
    CompletedActivities { activities: Vec<ActivitySummary> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    UnsupportedSchema(u32),
    NonMonotonicSample,
    NoSnapshot,
    InvalidCommand(String),
}

impl Display for EngineError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedSchema(version) => write!(formatter, "不支持快照版本 {version}"),
            Self::NonMonotonicSample => formatter.write_str("采样单调时间没有前进"),
            Self::NoSnapshot => formatter.write_str("尚无可用快照"),
            Self::InvalidCommand(message) => formatter.write_str(message),
        }
    }
}

impl Error for EngineError {}

use serde::{Deserialize, Serialize};
use storpulse_core::model::RawSnapshot;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "command",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ClientMessage {
    Connect {
        protocol_version: u32,
        snapshot_schema_version: u32,
        run_id: String,
        nonce: String,
        client_process_id: u32,
    },
    StartCollection {
        protocol_version: u32,
    },
    StopCollection {
        protocol_version: u32,
        last_sequence: Option<u64>,
    },
    AcknowledgeStop {
        protocol_version: u32,
    },
}

impl ClientMessage {
    pub fn protocol_version(&self) -> u32 {
        match self {
            Self::Connect {
                protocol_version, ..
            }
            | Self::StartCollection { protocol_version }
            | Self::StopCollection {
                protocol_version, ..
            }
            | Self::AcknowledgeStop { protocol_version } => *protocol_version,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "status",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ServiceMessage {
    Ready {
        protocol_version: u32,
        snapshot_schema_version: u32,
        service_process_id: u32,
        sample_interval_milliseconds: u64,
    },
    CollectionStarted {
        protocol_version: u32,
        first_sequence: u64,
    },
    Snapshot {
        protocol_version: u32,
        sequence: u64,
        snapshot: Box<RawSnapshot>,
    },
    Stopped {
        protocol_version: u32,
        final_sequence: Option<u64>,
    },
    Failed {
        protocol_version: u32,
        phase: FailurePhase,
        safe_error_code: SafeErrorCode,
        native_code: Option<u32>,
    },
}

impl ServiceMessage {
    pub fn protocol_version(&self) -> u32 {
        match self {
            Self::Ready {
                protocol_version, ..
            }
            | Self::CollectionStarted {
                protocol_version, ..
            }
            | Self::Snapshot {
                protocol_version, ..
            }
            | Self::Stopped {
                protocol_version, ..
            }
            | Self::Failed {
                protocol_version, ..
            } => *protocol_version,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::Ready { .. } => "ready",
            Self::CollectionStarted { .. } => "collection_started",
            Self::Snapshot { .. } => "snapshot",
            Self::Stopped { .. } => "stopped",
            Self::Failed { .. } => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FailurePhase {
    Connection,
    Authentication,
    Protocol,
    Etw,
    ProcessIdentity,
    Snapshot,
    Shutdown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SafeErrorCode {
    UnsupportedProtocol,
    UnsupportedSnapshotSchema,
    InvalidStateTransition,
    MessageTooLarge,
    Timeout,
    ClientDisconnected,
    AuthenticationFailed,
    EtwStartFailed,
    SnapshotInvalid,
    SequenceGap,
    ShutdownFailed,
}

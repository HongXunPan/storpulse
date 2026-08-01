use std::fmt::{Display, Formatter};

use serde::{Deserialize, Serialize};

use crate::{
    PROTOCOL_VERSION, SAMPLE_INTERVAL_MILLISECONDS, SNAPSHOT_SCHEMA_VERSION, ServiceMessage,
};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CollectionState {
    #[default]
    Disconnected,
    Connecting,
    Ready,
    Collecting,
    Draining,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionError {
    InvalidTransition {
        state: CollectionState,
        message: &'static str,
    },
    UnsupportedProtocol(u32),
    UnsupportedSnapshotSchema(u32),
    InvalidSampleInterval(u64),
    InvalidFirstSequence(u64),
    UnexpectedSequence {
        expected: u64,
        received: u64,
    },
    NonMonotonicSnapshot,
    StopSequenceMismatch {
        expected: Option<u64>,
        received: Option<u64>,
    },
}

impl Display for SessionError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidTransition { state, message } => {
                write!(formatter, "状态 {state:?} 不接受消息 {message}")
            }
            Self::UnsupportedProtocol(version) => write!(formatter, "不支持协议版本 {version}"),
            Self::UnsupportedSnapshotSchema(version) => {
                write!(formatter, "不支持快照版本 {version}")
            }
            Self::InvalidSampleInterval(interval) => {
                write!(formatter, "不支持采样间隔 {interval} 毫秒")
            }
            Self::InvalidFirstSequence(sequence) => {
                write!(formatter, "首个快照序号必须为 1，实际为 {sequence}")
            }
            Self::UnexpectedSequence { expected, received } => {
                write!(
                    formatter,
                    "快照序号不连续：期望 {expected}，实际 {received}"
                )
            }
            Self::NonMonotonicSnapshot => formatter.write_str("快照单调时间没有前进"),
            Self::StopSequenceMismatch { expected, received } => {
                write!(
                    formatter,
                    "停止序号不一致：期望 {expected:?}，实际 {received:?}"
                )
            }
        }
    }
}

impl std::error::Error for SessionError {}

#[derive(Debug, Default)]
pub struct CollectionSession {
    state: CollectionState,
    last_sequence: Option<u64>,
    last_monotonic_nanoseconds: Option<u64>,
}

impl CollectionSession {
    pub fn state(&self) -> CollectionState {
        self.state
    }

    pub fn last_sequence(&self) -> Option<u64> {
        self.last_sequence
    }

    pub fn begin_connecting(&mut self) -> Result<(), SessionError> {
        self.transition_from(
            CollectionState::Disconnected,
            CollectionState::Connecting,
            "connect",
        )
    }

    pub fn request_stop(&mut self) -> Result<(), SessionError> {
        self.transition_from(
            CollectionState::Collecting,
            CollectionState::Draining,
            "stop_collection",
        )
    }

    pub fn fail(&mut self) {
        self.state = CollectionState::Failed;
    }

    pub fn observe(&mut self, message: &ServiceMessage) -> Result<(), SessionError> {
        let result = self.observe_inner(message);
        if result.is_err() {
            self.fail();
        }
        result
    }

    fn observe_inner(&mut self, message: &ServiceMessage) -> Result<(), SessionError> {
        if message.protocol_version() != PROTOCOL_VERSION {
            return Err(SessionError::UnsupportedProtocol(
                message.protocol_version(),
            ));
        }
        match message {
            ServiceMessage::Ready {
                snapshot_schema_version,
                sample_interval_milliseconds,
                ..
            } => self.accept_ready(*snapshot_schema_version, *sample_interval_milliseconds),
            ServiceMessage::CollectionStarted { first_sequence, .. } => {
                self.accept_collection_started(*first_sequence)
            }
            ServiceMessage::Snapshot {
                sequence, snapshot, ..
            } => self.accept_snapshot(*sequence, snapshot),
            ServiceMessage::Stopped { final_sequence, .. } => self.accept_stopped(*final_sequence),
            ServiceMessage::Failed { .. } => {
                self.fail();
                Ok(())
            }
        }
    }

    fn accept_ready(
        &mut self,
        snapshot_schema_version: u32,
        sample_interval_milliseconds: u64,
    ) -> Result<(), SessionError> {
        self.require_state(CollectionState::Connecting, "ready")?;
        if snapshot_schema_version != SNAPSHOT_SCHEMA_VERSION {
            return Err(SessionError::UnsupportedSnapshotSchema(
                snapshot_schema_version,
            ));
        }
        if sample_interval_milliseconds != SAMPLE_INTERVAL_MILLISECONDS {
            return Err(SessionError::InvalidSampleInterval(
                sample_interval_milliseconds,
            ));
        }
        self.state = CollectionState::Ready;
        Ok(())
    }

    fn accept_collection_started(&mut self, first_sequence: u64) -> Result<(), SessionError> {
        self.require_state(CollectionState::Ready, "collection_started")?;
        if first_sequence != 1 {
            return Err(SessionError::InvalidFirstSequence(first_sequence));
        }
        self.state = CollectionState::Collecting;
        Ok(())
    }

    fn accept_snapshot(
        &mut self,
        sequence: u64,
        snapshot: &storpulse_core::model::RawSnapshot,
    ) -> Result<(), SessionError> {
        if !matches!(
            self.state,
            CollectionState::Collecting | CollectionState::Draining
        ) {
            return Err(SessionError::InvalidTransition {
                state: self.state,
                message: "snapshot",
            });
        }
        if snapshot.schema_version != SNAPSHOT_SCHEMA_VERSION {
            return Err(SessionError::UnsupportedSnapshotSchema(
                snapshot.schema_version,
            ));
        }
        let expected = self
            .last_sequence
            .map_or(1, |value| value.saturating_add(1));
        if sequence != expected {
            return Err(SessionError::UnexpectedSequence {
                expected,
                received: sequence,
            });
        }
        if self
            .last_monotonic_nanoseconds
            .is_some_and(|previous| snapshot.monotonic_nanoseconds <= previous)
        {
            return Err(SessionError::NonMonotonicSnapshot);
        }
        self.last_sequence = Some(sequence);
        self.last_monotonic_nanoseconds = Some(snapshot.monotonic_nanoseconds);
        Ok(())
    }

    fn accept_stopped(&mut self, final_sequence: Option<u64>) -> Result<(), SessionError> {
        self.require_state(CollectionState::Draining, "stopped")?;
        if final_sequence != self.last_sequence {
            return Err(SessionError::StopSequenceMismatch {
                expected: self.last_sequence,
                received: final_sequence,
            });
        }
        self.state = CollectionState::Stopped;
        Ok(())
    }

    fn transition_from(
        &mut self,
        expected: CollectionState,
        next: CollectionState,
        message: &'static str,
    ) -> Result<(), SessionError> {
        if let Err(error) = self.require_state(expected, message) {
            self.fail();
            return Err(error);
        }
        self.state = next;
        Ok(())
    }

    fn require_state(
        &self,
        expected: CollectionState,
        message: &'static str,
    ) -> Result<(), SessionError> {
        if self.state != expected {
            return Err(SessionError::InvalidTransition {
                state: self.state,
                message,
            });
        }
        Ok(())
    }
}

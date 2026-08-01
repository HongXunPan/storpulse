use std::fmt::{Display, Formatter};

use storpulse_windows_service_contract::{PROTOCOL_VERSION, ServiceMessage};

use crate::{CollectorEvent, SessionAccumulator};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeError {
    NonMonotonicPublish { previous: u64, received: u64 },
    SequenceExhausted,
}

impl Display for RuntimeError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NonMonotonicPublish { previous, received } => {
                write!(formatter, "发布单调时间没有前进：{previous} -> {received}")
            }
            Self::SequenceExhausted => formatter.write_str("快照序号已经耗尽"),
        }
    }
}

impl std::error::Error for RuntimeError {}

#[derive(Debug)]
pub struct SnapshotPublisher {
    accumulator: SessionAccumulator,
    last_monotonic_nanoseconds: Option<u64>,
    next_sequence: u64,
}

impl SnapshotPublisher {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe(&mut self, event: CollectorEvent) {
        self.accumulator.observe(event);
    }

    pub fn publish(
        &mut self,
        captured_at: String,
        monotonic_nanoseconds: u64,
        collection_duration_nanoseconds: u64,
    ) -> Result<ServiceMessage, RuntimeError> {
        if let Some(previous) = self.last_monotonic_nanoseconds
            && monotonic_nanoseconds <= previous
        {
            return Err(RuntimeError::NonMonotonicPublish {
                previous,
                received: monotonic_nanoseconds,
            });
        }
        let sequence = self.next_sequence;
        self.next_sequence = self
            .next_sequence
            .checked_add(1)
            .ok_or(RuntimeError::SequenceExhausted)?;
        let snapshot = self.accumulator.snapshot(
            captured_at,
            monotonic_nanoseconds,
            collection_duration_nanoseconds,
        );
        self.last_monotonic_nanoseconds = Some(monotonic_nanoseconds);
        Ok(ServiceMessage::Snapshot {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            snapshot: Box::new(snapshot),
        })
    }
}

impl Default for SnapshotPublisher {
    fn default() -> Self {
        Self {
            accumulator: SessionAccumulator::default(),
            last_monotonic_nanoseconds: None,
            next_sequence: 1,
        }
    }
}

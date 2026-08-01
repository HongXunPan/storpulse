use std::fmt::{Display, Formatter};

use crate::{ClientMessage, CollectionState, PROTOCOL_VERSION, SNAPSHOT_SCHEMA_VERSION};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionRequest {
    pub run_id: String,
    pub nonce: String,
    pub client_process_id: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServiceSessionError {
    InvalidTransition {
        state: CollectionState,
        message: &'static str,
    },
    UnsupportedProtocol(u32),
    UnsupportedSnapshotSchema(u32),
    InvalidRunId,
    InvalidNonce,
    InvalidClientProcessId,
    StopSequenceMismatch {
        expected: Option<u64>,
        received: Option<u64>,
    },
}

impl Display for ServiceSessionError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidTransition { state, message } => {
                write!(formatter, "服务状态 {state:?} 不接受命令 {message}")
            }
            Self::UnsupportedProtocol(version) => write!(formatter, "不支持协议版本 {version}"),
            Self::UnsupportedSnapshotSchema(version) => {
                write!(formatter, "不支持快照版本 {version}")
            }
            Self::InvalidRunId => formatter.write_str("运行标识不符合安全格式"),
            Self::InvalidNonce => formatter.write_str("连接随机数不符合安全格式"),
            Self::InvalidClientProcessId => formatter.write_str("客户端进程标识无效"),
            Self::StopSequenceMismatch { expected, received } => write!(
                formatter,
                "客户端停止序号不一致：期望 {expected:?}，实际 {received:?}"
            ),
        }
    }
}

impl std::error::Error for ServiceSessionError {}

#[derive(Debug, Default)]
pub struct ServiceCommandSession {
    state: CollectionState,
}

impl ServiceCommandSession {
    pub fn state(&self) -> CollectionState {
        self.state
    }

    pub fn accept_connect(
        &mut self,
        message: ClientMessage,
    ) -> Result<ConnectionRequest, ServiceSessionError> {
        self.require_state(CollectionState::Disconnected, message.kind())?;
        let ClientMessage::Connect {
            protocol_version,
            snapshot_schema_version,
            run_id,
            nonce,
            client_process_id,
        } = message
        else {
            return self.fail(ServiceSessionError::InvalidTransition {
                state: self.state,
                message: message.kind(),
            });
        };
        self.validate_protocol(protocol_version)?;
        if snapshot_schema_version != SNAPSHOT_SCHEMA_VERSION {
            return self.fail(ServiceSessionError::UnsupportedSnapshotSchema(
                snapshot_schema_version,
            ));
        }
        if !valid_run_id(&run_id) {
            return self.fail(ServiceSessionError::InvalidRunId);
        }
        if nonce.len() != 64 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return self.fail(ServiceSessionError::InvalidNonce);
        }
        if client_process_id == 0 {
            return self.fail(ServiceSessionError::InvalidClientProcessId);
        }
        self.state = CollectionState::Connecting;
        Ok(ConnectionRequest {
            run_id,
            nonce,
            client_process_id,
        })
    }

    pub fn mark_ready(&mut self) -> Result<(), ServiceSessionError> {
        self.transition(CollectionState::Connecting, CollectionState::Ready, "ready")
    }

    pub fn accept_start(&mut self, message: &ClientMessage) -> Result<(), ServiceSessionError> {
        self.require_state(CollectionState::Ready, message.kind())?;
        let ClientMessage::StartCollection { protocol_version } = message else {
            return self.fail(ServiceSessionError::InvalidTransition {
                state: self.state,
                message: message.kind(),
            });
        };
        self.validate_protocol(*protocol_version)?;
        self.state = CollectionState::Collecting;
        Ok(())
    }

    pub fn accept_stop(
        &mut self,
        message: &ClientMessage,
        service_last_sequence: Option<u64>,
    ) -> Result<(), ServiceSessionError> {
        self.require_state(CollectionState::Collecting, message.kind())?;
        let ClientMessage::StopCollection {
            protocol_version,
            last_sequence,
        } = message
        else {
            return self.fail(ServiceSessionError::InvalidTransition {
                state: self.state,
                message: message.kind(),
            });
        };
        self.validate_protocol(*protocol_version)?;
        let client_ahead = match (*last_sequence, service_last_sequence) {
            (Some(received), Some(expected)) => received > expected,
            (Some(_), None) => true,
            (None, _) => false,
        };
        if client_ahead {
            return self.fail(ServiceSessionError::StopSequenceMismatch {
                expected: service_last_sequence,
                received: *last_sequence,
            });
        }
        self.state = CollectionState::Draining;
        Ok(())
    }

    pub fn mark_stopped(&mut self) -> Result<(), ServiceSessionError> {
        self.transition(
            CollectionState::Draining,
            CollectionState::Stopped,
            "stopped",
        )
    }

    pub fn accept_acknowledgement(
        &mut self,
        message: &ClientMessage,
    ) -> Result<(), ServiceSessionError> {
        self.require_state(CollectionState::Stopped, message.kind())?;
        let ClientMessage::AcknowledgeStop { protocol_version } = message else {
            return self.fail(ServiceSessionError::InvalidTransition {
                state: self.state,
                message: message.kind(),
            });
        };
        self.validate_protocol(*protocol_version)
    }

    pub fn fail_session(&mut self) {
        self.state = CollectionState::Failed;
    }

    fn validate_protocol(&mut self, version: u32) -> Result<(), ServiceSessionError> {
        if version != PROTOCOL_VERSION {
            return self.fail(ServiceSessionError::UnsupportedProtocol(version));
        }
        Ok(())
    }

    fn transition(
        &mut self,
        expected: CollectionState,
        next: CollectionState,
        message: &'static str,
    ) -> Result<(), ServiceSessionError> {
        self.require_state(expected, message)?;
        self.state = next;
        Ok(())
    }

    fn require_state(
        &mut self,
        expected: CollectionState,
        message: &'static str,
    ) -> Result<(), ServiceSessionError> {
        if self.state != expected {
            return self.fail(ServiceSessionError::InvalidTransition {
                state: self.state,
                message,
            });
        }
        Ok(())
    }

    fn fail<T>(&mut self, error: ServiceSessionError) -> Result<T, ServiceSessionError> {
        self.fail_session();
        Err(error)
    }
}

fn valid_run_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

use storpulse_windows_service_contract::{
    FailurePhase, PROTOCOL_VERSION, SafeErrorCode, ServiceMessage, ServiceSessionError,
};

use crate::RuntimeError;

use super::identity::IdentityError;
use super::{PipeError, PipeErrorKind, TraceError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServiceRunError {
    pub phase: FailurePhase,
    pub safe_error_code: SafeErrorCode,
    pub native_code: Option<u32>,
}

impl ServiceRunError {
    pub(super) fn authentication(native_code: Option<u32>) -> Self {
        Self {
            phase: FailurePhase::Authentication,
            safe_error_code: SafeErrorCode::AuthenticationFailed,
            native_code,
        }
    }

    pub(super) fn shutdown(native_code: Option<u32>) -> Self {
        Self {
            phase: FailurePhase::Shutdown,
            safe_error_code: SafeErrorCode::ShutdownFailed,
            native_code,
        }
    }

    pub(super) fn message(self) -> ServiceMessage {
        ServiceMessage::Failed {
            protocol_version: PROTOCOL_VERSION,
            phase: self.phase,
            safe_error_code: self.safe_error_code,
            native_code: self.native_code,
        }
    }
}

impl std::fmt::Display for ServiceRunError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "Windows 服务运行失败：{:?} / {:?} / {:?}",
            self.phase, self.safe_error_code, self.native_code
        )
    }
}

impl std::error::Error for ServiceRunError {}

impl From<PipeError> for ServiceRunError {
    fn from(error: PipeError) -> Self {
        let (phase, safe_error_code) = match error.kind {
            PipeErrorKind::Timeout => {
                let phase = if error.operation.starts_with("connect_") {
                    FailurePhase::Connection
                } else {
                    FailurePhase::Protocol
                };
                (phase, SafeErrorCode::Timeout)
            }
            PipeErrorKind::StopRequested => (FailurePhase::Shutdown, SafeErrorCode::ShutdownFailed),
            PipeErrorKind::PeerDisconnected => {
                (FailurePhase::Connection, SafeErrorCode::ClientDisconnected)
            }
            PipeErrorKind::InvalidFrame if error.operation == "frame_too_large" => {
                (FailurePhase::Protocol, SafeErrorCode::MessageTooLarge)
            }
            PipeErrorKind::InvalidFrame => (FailurePhase::Protocol, SafeErrorCode::InvalidMessage),
            PipeErrorKind::Native => (FailurePhase::Connection, SafeErrorCode::ConnectionFailed),
        };
        Self {
            phase,
            safe_error_code,
            native_code: error.native_code,
        }
    }
}

impl From<ServiceSessionError> for ServiceRunError {
    fn from(error: ServiceSessionError) -> Self {
        let (phase, safe_error_code) = match error {
            ServiceSessionError::UnsupportedProtocol(_) => {
                (FailurePhase::Protocol, SafeErrorCode::UnsupportedProtocol)
            }
            ServiceSessionError::UnsupportedSnapshotSchema(_) => (
                FailurePhase::Protocol,
                SafeErrorCode::UnsupportedSnapshotSchema,
            ),
            ServiceSessionError::InvalidTransition { .. } => (
                FailurePhase::Protocol,
                SafeErrorCode::InvalidStateTransition,
            ),
            ServiceSessionError::InvalidNonce => (
                FailurePhase::Authentication,
                SafeErrorCode::AuthenticationFailed,
            ),
            ServiceSessionError::StopSequenceMismatch { .. } => {
                (FailurePhase::Protocol, SafeErrorCode::SequenceGap)
            }
            ServiceSessionError::InvalidRunId | ServiceSessionError::InvalidClientProcessId => {
                (FailurePhase::Protocol, SafeErrorCode::InvalidMessage)
            }
        };
        Self {
            phase,
            safe_error_code,
            native_code: None,
        }
    }
}

impl From<TraceError> for ServiceRunError {
    fn from(error: TraceError) -> Self {
        Self {
            phase: FailurePhase::Etw,
            safe_error_code: SafeErrorCode::EtwStartFailed,
            native_code: Some(error.native_code),
        }
    }
}

impl From<IdentityError> for ServiceRunError {
    fn from(error: IdentityError) -> Self {
        let _ = error.operation;
        Self::authentication(Some(error.native_code))
    }
}

impl From<RuntimeError> for ServiceRunError {
    fn from(error: RuntimeError) -> Self {
        let safe_error_code = match error {
            RuntimeError::NonMonotonicPublish { .. } => SafeErrorCode::SnapshotInvalid,
            RuntimeError::SequenceExhausted => SafeErrorCode::SequenceGap,
        };
        Self {
            phase: FailurePhase::Snapshot,
            safe_error_code,
            native_code: None,
        }
    }
}

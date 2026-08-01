use storpulse_windows_ipc::{PipeError, PipeErrorKind};
use storpulse_windows_service_contract::{FailurePhase, SafeErrorCode, SessionError};

use crate::SafeFailure;

#[derive(Debug, Clone, Copy)]
pub(super) struct ClientError {
    phase: &'static str,
    safe_error_code: &'static str,
    native_code: Option<u32>,
}

impl ClientError {
    pub(super) fn new(
        phase: &'static str,
        safe_error_code: &'static str,
        native_code: Option<u32>,
    ) -> Self {
        Self {
            phase,
            safe_error_code,
            native_code,
        }
    }

    pub(super) fn protocol(code: &'static str) -> Self {
        Self::new("protocol", code, None)
    }

    pub(super) fn remote(
        phase: FailurePhase,
        code: SafeErrorCode,
        native_code: Option<u32>,
    ) -> Self {
        Self::new(failure_phase(phase), safe_error_code(code), native_code)
    }

    pub(super) fn safe_failure(self) -> SafeFailure {
        SafeFailure::new(self.phase, self.safe_error_code, self.native_code)
    }
}

impl From<PipeError> for ClientError {
    fn from(error: PipeError) -> Self {
        let code = match error.kind {
            PipeErrorKind::Timeout => "pipe_timeout",
            PipeErrorKind::StopRequested => "pipe_stop_requested",
            PipeErrorKind::PeerDisconnected => "service_disconnected",
            PipeErrorKind::InvalidFrame => "invalid_service_frame",
            PipeErrorKind::Native => "pipe_native_error",
        };
        Self::new("connection", code, error.native_code)
    }
}

impl From<SessionError> for ClientError {
    fn from(_error: SessionError) -> Self {
        Self::protocol("protocol_validation_failed")
    }
}

fn failure_phase(phase: FailurePhase) -> &'static str {
    match phase {
        FailurePhase::ServiceLifecycle => "service_lifecycle",
        FailurePhase::Connection => "connection",
        FailurePhase::Authentication => "authentication",
        FailurePhase::Protocol => "protocol",
        FailurePhase::Etw => "etw",
        FailurePhase::ProcessIdentity => "process_identity",
        FailurePhase::Snapshot => "snapshot",
        FailurePhase::Shutdown => "shutdown",
    }
}

fn safe_error_code(code: SafeErrorCode) -> &'static str {
    match code {
        SafeErrorCode::ServiceStatusFailed => "service_status_failed",
        SafeErrorCode::ConnectionFailed => "connection_failed",
        SafeErrorCode::UnsupportedProtocol => "unsupported_protocol",
        SafeErrorCode::UnsupportedSnapshotSchema => "unsupported_snapshot_schema",
        SafeErrorCode::InvalidStateTransition => "invalid_state_transition",
        SafeErrorCode::InvalidMessage => "invalid_message",
        SafeErrorCode::MessageTooLarge => "message_too_large",
        SafeErrorCode::Timeout => "timeout",
        SafeErrorCode::ClientDisconnected => "client_disconnected",
        SafeErrorCode::AuthenticationFailed => "authentication_failed",
        SafeErrorCode::EtwStartFailed => "etw_start_failed",
        SafeErrorCode::SnapshotInvalid => "snapshot_invalid",
        SafeErrorCode::SequenceGap => "sequence_gap",
        SafeErrorCode::ShutdownFailed => "shutdown_failed",
    }
}

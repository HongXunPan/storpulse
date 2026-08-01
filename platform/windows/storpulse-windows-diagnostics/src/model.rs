use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use storpulse_windows_service_contract::{FailurePhase, PROTOCOL_VERSION, SafeErrorCode};

pub const DIAGNOSTIC_EVENT_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticComponent {
    App,
    Adapter,
    Service,
    Engine,
    Storage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticEventKind {
    ServiceSessionCreated,
    ClientAuthenticated,
    CollectionStarted,
    CollectionStopping,
    CollectionStopped,
    TerminationFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSeverity {
    Information,
    Warning,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticState {
    Connecting,
    Ready,
    Collecting,
    Draining,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticOsProduct {
    Windows10,
    Windows11,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticArchitecture {
    X64,
    Arm64,
    X86,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticModelError {
    InvalidRunId,
    InvalidServiceVersion,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticContext {
    run_id: String,
    service_version: String,
    os_product: DiagnosticOsProduct,
    os_build: Option<u32>,
    architecture: DiagnosticArchitecture,
}

impl DiagnosticContext {
    pub fn service(run_id: impl Into<String>) -> Result<Self, DiagnosticModelError> {
        let run_id = run_id.into();
        let service_version = env!("CARGO_PKG_VERSION").to_owned();
        if !valid_safe_identifier(&run_id, 128) {
            return Err(DiagnosticModelError::InvalidRunId);
        }
        if !valid_safe_identifier(&service_version, 64) {
            return Err(DiagnosticModelError::InvalidServiceVersion);
        }
        Ok(Self {
            run_id,
            service_version,
            os_product: DiagnosticOsProduct::Unknown,
            os_build: None,
            architecture: current_architecture(),
        })
    }

    pub fn replace_run_id(
        &mut self,
        run_id: impl Into<String>,
    ) -> Result<(), DiagnosticModelError> {
        let run_id = run_id.into();
        if !valid_safe_identifier(&run_id, 128) {
            return Err(DiagnosticModelError::InvalidRunId);
        }
        self.run_id = run_id;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticEvent {
    pub schema_version: u32,
    pub timestamp_utc: u64,
    pub monotonic_milliseconds: u64,
    pub run_id: String,
    pub component: DiagnosticComponent,
    pub phase: FailurePhase,
    pub event: DiagnosticEventKind,
    pub severity: DiagnosticSeverity,
    pub safe_error_code: Option<SafeErrorCode>,
    pub native_code: Option<u32>,
    pub app_version: Option<String>,
    pub service_version: String,
    pub protocol_version: u32,
    pub os_product: DiagnosticOsProduct,
    pub os_build: Option<u32>,
    pub architecture: DiagnosticArchitecture,
    pub state: DiagnosticState,
}

impl DiagnosticEvent {
    pub fn service_lifecycle(
        context: &DiagnosticContext,
        elapsed: Duration,
        event: DiagnosticEventKind,
        state: DiagnosticState,
    ) -> Self {
        Self::service(
            context,
            elapsed,
            FailurePhase::ServiceLifecycle,
            event,
            DiagnosticSeverity::Information,
            None,
            None,
            state,
        )
    }

    pub fn service_failure(
        context: &DiagnosticContext,
        elapsed: Duration,
        phase: FailurePhase,
        safe_error_code: SafeErrorCode,
        native_code: Option<u32>,
    ) -> Self {
        Self::service(
            context,
            elapsed,
            phase,
            DiagnosticEventKind::TerminationFailed,
            DiagnosticSeverity::Error,
            Some(safe_error_code),
            native_code,
            DiagnosticState::Failed,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn service(
        context: &DiagnosticContext,
        elapsed: Duration,
        phase: FailurePhase,
        event: DiagnosticEventKind,
        severity: DiagnosticSeverity,
        safe_error_code: Option<SafeErrorCode>,
        native_code: Option<u32>,
        state: DiagnosticState,
    ) -> Self {
        Self {
            schema_version: DIAGNOSTIC_EVENT_SCHEMA_VERSION,
            timestamp_utc: utc_milliseconds(),
            monotonic_milliseconds: elapsed.as_millis().min(u128::from(u64::MAX)) as u64,
            run_id: context.run_id.clone(),
            component: DiagnosticComponent::Service,
            phase,
            event,
            severity,
            safe_error_code,
            native_code,
            app_version: None,
            service_version: context.service_version.clone(),
            protocol_version: PROTOCOL_VERSION,
            os_product: context.os_product,
            os_build: context.os_build,
            architecture: context.architecture,
            state,
        }
    }
}

fn utc_milliseconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

fn valid_safe_identifier(value: &str, maximum_length: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

const fn current_architecture() -> DiagnosticArchitecture {
    if cfg!(target_arch = "x86_64") {
        DiagnosticArchitecture::X64
    } else if cfg!(target_arch = "aarch64") {
        DiagnosticArchitecture::Arm64
    } else if cfg!(target_arch = "x86") {
        DiagnosticArchitecture::X86
    } else {
        DiagnosticArchitecture::Unknown
    }
}

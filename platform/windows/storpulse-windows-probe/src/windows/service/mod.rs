mod auth;
mod client;
mod failure_delivery;
mod identity;
mod protocol;
mod runtime;
mod scm;
mod transport;

use windows_sys::Win32::Foundation::GetLastError;

use super::error::{NativeFailure, RunError};
use crate::options::ProbeOptions;

pub(super) const SERVICE_NAME: &str = "StorPulseStage0Collector";
pub(super) const SERVICE_ETW_SESSION_NAME: &str = "StorPulse.Stage0.Service";

pub(super) fn run_dispatcher() -> Result<(), RunError> {
    runtime::run_dispatcher().map_err(|error| RunError::new(error.safe_message()))
}

pub(super) fn run_diagnostic(options: ProbeOptions) -> Result<(), RunError> {
    client::run(options).map_err(|error| RunError::new(error.safe_message()))
}

pub(super) struct ServiceFailure {
    phase: &'static str,
    api: &'static str,
    code: u32,
}

impl ServiceFailure {
    fn new(phase: &'static str, api: &'static str, code: u32) -> Self {
        Self { phase, api, code }
    }

    fn last(phase: &'static str, api: &'static str) -> Self {
        Self::new(phase, api, unsafe { GetLastError() })
    }

    fn from_native(error: NativeFailure) -> Self {
        Self::new(error.phase, error.api, error.code)
    }

    fn from_remote(phase: &str, api: &str, code: u32) -> Self {
        if phase == "ipc"
            && let Some(api) = trusted_remote_api(api)
        {
            return Self::new("ipc", api, code);
        }
        Self::new("service_runtime", "remote_service_failure", code)
    }

    fn safe_message(&self) -> String {
        format!("{}：{} ({})", self.phase, self.api, self.code)
    }

    fn diagnostic(&self) -> crate::model::DiagnosticError {
        crate::model::DiagnosticError {
            phase: self.phase,
            api: self.api,
            code: self.code,
            category: match self.code {
                5 => "access_denied",
                13 | 87 => "invalid_data",
                1460 => "timeout",
                _ => "native_error",
            },
        }
    }
}

const TRUSTED_REMOTE_APIS: &[&str] = &[
    "serde_json.serialize.response",
    "serde_json.deserialize.response.trailing",
    "serde_json.deserialize.response.io",
    "serde_json.deserialize.response.syntax",
    "serde_json.deserialize.response.eof",
    "serde_json.deserialize.response.data",
    "serde_json.deserialize.response.root",
    "serde_json.deserialize.response.missing_status",
    "serde_json.deserialize.response.unknown_status",
    "serde_json.deserialize.response.completed.missing_etw",
    "serde_json.deserialize.response.completed.missing_service",
    "serde_json.deserialize.response.completed.etw_shape",
    "serde_json.deserialize.response.completed.etw.events_by_opcode",
    "serde_json.deserialize.response.completed.etw.top_processes",
    "serde_json.deserialize.response.completed.etw.scalar",
    "serde_json.deserialize.response.completed.service_shape",
    "serde_json.deserialize.response.completed.service.self_measurements",
    "serde_json.deserialize.response.completed.service.scalar",
    "serde_json.deserialize.response.completed.wrapper",
];

fn trusted_remote_api(api: &str) -> Option<&'static str> {
    TRUSTED_REMOTE_APIS
        .iter()
        .copied()
        .find(|trusted| *trusted == api)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_failure_only_accepts_known_ipc_diagnostics() {
        let trusted = ServiceFailure::from_remote(
            "ipc",
            "serde_json.deserialize.response.completed.etw.events_by_opcode",
            13,
        );
        assert_eq!(trusted.phase, "ipc");
        assert_eq!(
            trusted.api,
            "serde_json.deserialize.response.completed.etw.events_by_opcode"
        );

        let untrusted = ServiceFailure::from_remote("ipc", "untrusted.payload", 13);
        assert_eq!(untrusted.phase, "service_runtime");
        assert_eq!(untrusted.api, "remote_service_failure");
    }
}

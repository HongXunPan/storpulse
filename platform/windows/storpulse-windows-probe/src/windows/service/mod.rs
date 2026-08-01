mod auth;
mod client;
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

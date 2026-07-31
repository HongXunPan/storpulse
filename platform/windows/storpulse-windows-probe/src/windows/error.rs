use windows_sys::Win32::Foundation::{
    ERROR_ACCESS_DENIED, ERROR_ALREADY_EXISTS, ERROR_INVALID_HANDLE, ERROR_INVALID_PARAMETER,
    GetLastError,
};

use crate::model::DiagnosticError;

pub(crate) struct RunError {
    message: String,
}

impl RunError {
    pub(super) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    pub fn safe_message(&self) -> &str {
        &self.message
    }
}

#[derive(Clone)]
pub(super) struct NativeFailure {
    pub(super) phase: &'static str,
    pub(super) api: &'static str,
    pub(super) code: u32,
    pub(super) session_started: bool,
}

impl NativeFailure {
    pub(super) fn new(phase: &'static str, api: &'static str, code: u32) -> Self {
        Self::new_with_session(phase, api, code, false)
    }

    pub(super) fn new_with_session(
        phase: &'static str,
        api: &'static str,
        code: u32,
        session_started: bool,
    ) -> Self {
        Self {
            phase,
            api,
            code,
            session_started,
        }
    }

    pub(super) fn last(phase: &'static str, api: &'static str) -> Self {
        // SAFETY：GetLastError 无参数且仅读取当前线程错误状态。
        Self::new(phase, api, unsafe { GetLastError() })
    }

    pub(super) fn diagnostic(&self) -> DiagnosticError {
        DiagnosticError {
            phase: self.phase,
            api: self.api,
            code: self.code,
            category: error_category(self.code),
        }
    }
}

fn error_category(code: u32) -> &'static str {
    match code {
        ERROR_ACCESS_DENIED => "access_denied",
        ERROR_ALREADY_EXISTS => "session_conflict",
        ERROR_INVALID_HANDLE => "invalid_handle",
        ERROR_INVALID_PARAMETER => "invalid_parameter",
        1460 => "timeout",
        _ => "native_error",
    }
}

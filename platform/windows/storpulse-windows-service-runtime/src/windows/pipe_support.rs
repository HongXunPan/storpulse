use std::fmt::{Display, Formatter};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use windows_sys::Win32::Foundation::{
    ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED, GetLastError, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::PSECURITY_DESCRIPTOR;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipeErrorKind {
    Native,
    Timeout,
    StopRequested,
    PeerDisconnected,
    InvalidFrame,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PipeError {
    pub kind: PipeErrorKind,
    pub operation: &'static str,
    pub native_code: Option<u32>,
}

impl PipeError {
    pub(super) fn native(operation: &'static str, code: u32) -> Self {
        let kind = if disconnected(code) {
            PipeErrorKind::PeerDisconnected
        } else {
            PipeErrorKind::Native
        };
        Self {
            kind,
            operation,
            native_code: Some(code),
        }
    }

    pub(super) fn last(operation: &'static str) -> Self {
        // SAFETY：GetLastError 无参数且仅读取当前线程错误状态。
        Self::native(operation, unsafe { GetLastError() })
    }

    pub(super) fn timeout(operation: &'static str) -> Self {
        Self {
            kind: PipeErrorKind::Timeout,
            operation,
            native_code: Some(1460),
        }
    }

    pub(super) fn stopped(operation: &'static str) -> Self {
        Self {
            kind: PipeErrorKind::StopRequested,
            operation,
            native_code: Some(995),
        }
    }

    pub(super) fn invalid_frame(operation: &'static str) -> Self {
        Self {
            kind: PipeErrorKind::InvalidFrame,
            operation,
            native_code: None,
        }
    }
}

impl Display for PipeError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "产品管道操作失败：{} / {:?} / {:?}",
            self.operation, self.kind, self.native_code
        )
    }
}

impl std::error::Error for PipeError {}

pub(super) struct SecurityDescriptor {
    pub(super) pointer: PSECURITY_DESCRIPTOR,
}

impl SecurityDescriptor {
    pub(super) fn new(sddl: &str) -> Result<Self, PipeError> {
        let sddl = wide(sddl);
        let mut pointer = std::ptr::null_mut();
        // SAFETY：输入是 NUL 结尾固定 SDDL，系统分配返回的描述符。
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut pointer,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(PipeError::last("create_security_descriptor"));
        }
        Ok(Self { pointer })
    }
}

impl Drop for SecurityDescriptor {
    fn drop(&mut self) {
        // SAFETY：描述符由 ConvertStringSecurityDescriptorToSecurityDescriptorW 分配。
        unsafe { LocalFree(self.pointer) };
    }
}

pub(super) fn check_wait(
    operation: &'static str,
    deadline: Instant,
    stop_requested: Option<&AtomicBool>,
) -> Result<(), PipeError> {
    if stop_requested.is_some_and(|stop| stop.load(Ordering::Relaxed)) {
        return Err(PipeError::stopped(operation));
    }
    if Instant::now() >= deadline {
        return Err(PipeError::timeout(operation));
    }
    Ok(())
}

pub(super) fn disconnected(code: u32) -> bool {
    matches!(code, ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED)
}

pub(super) fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

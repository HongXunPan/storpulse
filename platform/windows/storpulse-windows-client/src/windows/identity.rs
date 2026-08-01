use std::mem::size_of;

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, HANDLE};
use windows_sys::Win32::Security::{
    GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use super::ClientError;

pub(super) fn current_process_elevated() -> Result<bool, ClientError> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY：当前进程伪句柄始终有效，只申请查询 token 提升状态所需权限。
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(last_error("open_process_token_failed"));
    }
    let mut elevation = TOKEN_ELEVATION::default();
    let mut returned = 0;
    // SAFETY：查询类型和 TOKEN_ELEVATION 缓冲区大小一致。
    let succeeded = unsafe {
        GetTokenInformation(
            token,
            TokenElevation,
            (&mut elevation as *mut TOKEN_ELEVATION).cast(),
            size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        )
    };
    // SAFETY：token 由 OpenProcessToken 返回，只关闭一次。
    unsafe { CloseHandle(token) };
    if succeeded == 0 {
        return Err(last_error("read_token_elevation_failed"));
    }
    Ok(elevation.TokenIsElevated != 0)
}

fn last_error(code: &'static str) -> ClientError {
    ClientError::new(
        "environment",
        code,
        // SAFETY：GetLastError 无参数且仅读取当前线程错误状态。
        Some(unsafe { GetLastError() }),
    )
}

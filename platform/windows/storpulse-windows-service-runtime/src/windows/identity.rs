use std::mem::size_of;

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_INSUFFICIENT_BUFFER, GetLastError, HANDLE,
};
use windows_sys::Win32::Security::{
    CreateWellKnownSid, EqualSid, GetTokenInformation, SECURITY_MAX_SID_SIZE, TOKEN_ELEVATION,
    TOKEN_QUERY, TOKEN_USER, TokenElevation, TokenUser, WinLocalSystemSid,
};
use windows_sys::Win32::System::Pipes::{GetNamedPipeClientProcessId, ImpersonateNamedPipeClient};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetCurrentThread, OpenProcessToken, OpenThreadToken,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct IdentityError {
    pub(super) operation: &'static str,
    pub(super) native_code: u32,
}

impl IdentityError {
    fn last(operation: &'static str) -> Self {
        // SAFETY：GetLastError 无参数且仅读取当前线程错误状态。
        Self {
            operation,
            native_code: unsafe { GetLastError() },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct ClientIdentity {
    pub(super) process_id: u32,
    pub(super) elevated: bool,
}

pub(super) fn current_process_is_local_system() -> Result<bool, IdentityError> {
    let mut local_system_sid = [0_u8; SECURITY_MAX_SID_SIZE as usize];
    let mut sid_size = local_system_sid.len() as u32;
    // SAFETY：固定缓冲区使用 SECURITY_MAX_SID_SIZE，可容纳 LocalSystem SID。
    if unsafe {
        CreateWellKnownSid(
            WinLocalSystemSid,
            std::ptr::null_mut(),
            local_system_sid.as_mut_ptr().cast(),
            &mut sid_size,
        )
    } == 0
    {
        return Err(IdentityError::last("CreateWellKnownSid"));
    }

    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY：当前进程伪句柄始终有效，只申请读取 token 身份所需权限。
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(IdentityError::last("OpenProcessToken"));
    }
    let result = token_user_is_local_system(token, local_system_sid.as_mut_ptr().cast());
    // SAFETY：token 由 OpenProcessToken 返回，只关闭一次。
    unsafe { CloseHandle(token) };
    result
}

pub(super) fn inspect_pipe_client(pipe: HANDLE) -> Result<ClientIdentity, IdentityError> {
    let mut process_id = 0;
    // SAFETY：pipe 是已连接并收到客户端消息的命名管道服务端句柄。
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut process_id) } == 0 {
        return Err(IdentityError::last("GetNamedPipeClientProcessId"));
    }
    // SAFETY：pipe 已收到客户端消息，允许服务端临时模拟该客户端。
    if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
        return Err(IdentityError::last("ImpersonateNamedPipeClient"));
    }
    let elevation = thread_token_elevation();
    // SAFETY：无论 token 查询是否成功，都必须恢复 LocalSystem 服务身份。
    let reverted = unsafe { windows_sys::Win32::Security::RevertToSelf() };
    if reverted == 0 {
        return Err(IdentityError::last("RevertToSelf"));
    }

    Ok(ClientIdentity {
        process_id,
        elevated: elevation?,
    })
}

pub(super) fn nonce_matches(expected: &str, actual: &str) -> bool {
    if expected.len() != actual.len() {
        return false;
    }
    expected
        .as_bytes()
        .iter()
        .zip(actual.as_bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

fn token_user_is_local_system(
    token: HANDLE,
    local_system_sid: windows_sys::Win32::Security::PSID,
) -> Result<bool, IdentityError> {
    let mut required_bytes = 0;
    // SAFETY：首次查询只获取所需缓冲区长度，不读取输出缓冲区。
    let queried = unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            std::ptr::null_mut(),
            0,
            &mut required_bytes,
        )
    };
    if queried != 0 || unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER {
        return Err(IdentityError::last("GetTokenInformation.TokenUser.size"));
    }

    let word_bytes = size_of::<usize>();
    let word_count = (required_bytes as usize).div_ceil(word_bytes);
    let mut buffer = vec![0_usize; word_count];
    // SAFETY：按 usize 对齐的缓冲区容量不小于系统返回的所需长度。
    if unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            required_bytes,
            &mut required_bytes,
        )
    } == 0
    {
        return Err(IdentityError::last("GetTokenInformation.TokenUser"));
    }
    // SAFETY：成功的 TokenUser 查询返回包含有效 User.Sid 的 TOKEN_USER。
    let token_user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    // SAFETY：两个 SID 均在各自缓冲区生命周期内有效。
    Ok(unsafe { EqualSid(token_user.User.Sid, local_system_sid) } != 0)
}

fn thread_token_elevation() -> Result<bool, IdentityError> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY：当前线程正在模拟命名管道客户端，只申请 TOKEN_QUERY。
    if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } == 0 {
        return Err(IdentityError::last("OpenThreadToken"));
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
    // SAFETY：token 由 OpenThreadToken 返回，只关闭一次。
    unsafe { CloseHandle(token) };
    if succeeded == 0 {
        return Err(IdentityError::last("GetTokenInformation.TokenElevation"));
    }
    Ok(elevation.TokenIsElevated != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_comparison_requires_exact_value_and_length() {
        assert!(nonce_matches("abcd", "abcd"));
        assert!(!nonce_matches("abcd", "abce"));
        assert!(!nonce_matches("abcd", "abc"));
    }
}

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::Security::{
    CheckTokenMembership, CreateWellKnownSid, GetTokenInformation, SECURITY_MAX_SID_SIZE,
    TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation, WinBuiltinPerfLoggingUsersSid,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use crate::model::ProbeEnvironment;

pub fn collect(process_id: u32) -> ProbeEnvironment {
    ProbeEnvironment {
        architecture: std::env::consts::ARCH,
        process_id,
        elevated: token_elevation(),
        performance_log_user: performance_log_membership(),
    }
}

fn token_elevation() -> Option<bool> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY：句柄和缓冲区均由当前进程持有，并在返回前释放。
    let opened = unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) };
    if opened == 0 {
        return None;
    }

    let mut elevation = TOKEN_ELEVATION::default();
    let mut returned = 0;
    // SAFETY：TOKEN_ELEVATION 缓冲区大小与 TokenElevation 查询类型匹配。
    let succeeded = unsafe {
        GetTokenInformation(
            token,
            TokenElevation,
            (&mut elevation as *mut TOKEN_ELEVATION).cast(),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        )
    };
    // SAFETY：token 是 OpenProcessToken 返回的有效句柄。
    unsafe { CloseHandle(token) };
    (succeeded != 0).then_some(elevation.TokenIsElevated != 0)
}

fn performance_log_membership() -> Option<bool> {
    let mut sid = [0_u8; SECURITY_MAX_SID_SIZE as usize];
    let mut sid_size = sid.len() as u32;
    // SAFETY：固定缓冲区大小使用 SECURITY_MAX_SID_SIZE，足以容纳已知 SID。
    let created = unsafe {
        CreateWellKnownSid(
            WinBuiltinPerfLoggingUsersSid,
            std::ptr::null_mut(),
            sid.as_mut_ptr().cast(),
            &mut sid_size,
        )
    };
    if created == 0 {
        return None;
    }

    let mut member = 0;
    // SAFETY：空 token 表示当前有效 token，SID 缓冲区在调用期间保持有效。
    let checked =
        unsafe { CheckTokenMembership(std::ptr::null_mut(), sid.as_mut_ptr().cast(), &mut member) };
    (checked != 0).then_some(member != 0)
}

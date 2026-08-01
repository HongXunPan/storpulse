use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{ERROR_SERVICE_SPECIFIC_ERROR, GetLastError};
use windows_sys::Win32::System::Services::{
    CloseServiceHandle, OpenSCManagerW, OpenServiceW, QueryServiceStatusEx, SC_HANDLE,
    SC_MANAGER_CONNECT, SC_STATUS_PROCESS_INFO, SERVICE_QUERY_STATUS, SERVICE_RUNNING,
    SERVICE_START, SERVICE_START_PENDING, SERVICE_STATUS_PROCESS, SERVICE_STOPPED, StartServiceW,
};

use super::{SERVICE_NAME, ServiceFailure};

pub(super) fn start(nonce: &str) -> Result<(), ServiceFailure> {
    let manager = ServiceHandle::open_manager()?;
    let service = manager.open_service(SERVICE_START | SERVICE_QUERY_STATUS)?;
    let status = service.query_status()?;
    if status.dwCurrentState != SERVICE_STOPPED {
        return Err(ServiceFailure::new(
            "service_control",
            "service_not_stopped",
            status.dwCurrentState,
        ));
    }

    let nonce = wide(nonce);
    let arguments = [nonce.as_ptr()];
    // SAFETY：服务句柄含 SERVICE_START 权限，参数在同步调用期间有效。
    if unsafe { StartServiceW(service.handle, arguments.len() as u32, arguments.as_ptr()) } == 0 {
        return Err(ServiceFailure::new(
            "service_control",
            "StartServiceW",
            unsafe { GetLastError() },
        ));
    }
    service.wait_for_running(Instant::now() + Duration::from_secs(15))
}

pub(super) fn wait_until_stopped(deadline: Instant) -> Result<bool, ServiceFailure> {
    let manager = ServiceHandle::open_manager()?;
    let service = manager.open_service(SERVICE_QUERY_STATUS)?;
    loop {
        let status = service.query_status()?;
        if status.dwCurrentState == SERVICE_STOPPED {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

struct ServiceHandle {
    handle: SC_HANDLE,
}

impl ServiceHandle {
    fn open_manager() -> Result<Self, ServiceFailure> {
        // SAFETY：空机器名和数据库名表示本机活动 SCM 数据库。
        let handle =
            unsafe { OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_CONNECT) };
        if handle.is_null() {
            return Err(ServiceFailure::last("service_control", "OpenSCManagerW"));
        }
        Ok(Self { handle })
    }

    fn open_service(&self, access: u32) -> Result<Self, ServiceFailure> {
        let name = wide(SERVICE_NAME);
        // SAFETY：SCM 句柄有效，服务名以 NUL 结尾。
        let handle = unsafe { OpenServiceW(self.handle, name.as_ptr(), access) };
        if handle.is_null() {
            return Err(ServiceFailure::last("service_control", "OpenServiceW"));
        }
        Ok(Self { handle })
    }

    fn query_status(&self) -> Result<SERVICE_STATUS_PROCESS, ServiceFailure> {
        let mut status = SERVICE_STATUS_PROCESS::default();
        let mut needed = 0;
        // SAFETY：输出缓冲区与 SERVICE_STATUS_PROCESS 类型和大小一致。
        let queried = unsafe {
            QueryServiceStatusEx(
                self.handle,
                SC_STATUS_PROCESS_INFO,
                (&mut status as *mut SERVICE_STATUS_PROCESS).cast(),
                std::mem::size_of::<SERVICE_STATUS_PROCESS>() as u32,
                &mut needed,
            )
        };
        if queried == 0 {
            return Err(ServiceFailure::last(
                "service_control",
                "QueryServiceStatusEx",
            ));
        }
        Ok(status)
    }

    fn wait_for_running(&self, deadline: Instant) -> Result<(), ServiceFailure> {
        loop {
            let status = self.query_status()?;
            if status.dwCurrentState == SERVICE_RUNNING {
                return Ok(());
            }
            if status.dwCurrentState != SERVICE_START_PENDING {
                let error_code = if status.dwWin32ExitCode == ERROR_SERVICE_SPECIFIC_ERROR {
                    status.dwServiceSpecificExitCode
                } else {
                    status.dwWin32ExitCode
                };
                return Err(ServiceFailure::new(
                    "service_control",
                    "service_start_failed",
                    error_code,
                ));
            }
            if Instant::now() >= deadline {
                return Err(ServiceFailure::new(
                    "service_control",
                    "service_start_timeout",
                    1460,
                ));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for ServiceHandle {
    fn drop(&mut self) {
        // SAFETY：句柄由 OpenSCManagerW 或 OpenServiceW 返回，只关闭一次。
        unsafe { CloseServiceHandle(self.handle) };
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

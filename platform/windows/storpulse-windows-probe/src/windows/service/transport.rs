use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde::de::DeserializeOwned;
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_NO_DATA, ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING, GENERIC_READ,
    GetLastError, HANDLE, INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_WRITE_DATA, OPEN_EXISTING, PIPE_ACCESS_DUPLEX,
    ReadFile, WriteFile,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_NOWAIT, PIPE_READMODE_MESSAGE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE, PIPE_WAIT, PeekNamedPipe,
    SetNamedPipeHandleState, WaitNamedPipeW,
};

use super::ServiceFailure;

pub(super) const PIPE_NAME: &str = r"\\.\pipe\StorPulse.Stage0.Collector.v1";
const PIPE_BUFFER_BYTES: u32 = 65_536;
const CLIENT_PIPE_ACCESS: u32 = GENERIC_READ | FILE_WRITE_DATA;
// LocalSystem 创建的管道默认处于系统完整性；显式使用中等完整性允许标准用户双向通信。
// 交互用户只获得 FILE_GENERIC_READ 与 FILE_WRITE_DATA，不包含创建管道实例权限。
const PIPE_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x0012008b;;;IU)S:(ML;;NW;;;ME)";

pub(super) struct Pipe {
    handle: HANDLE,
    server: bool,
}

impl Pipe {
    pub(super) fn create_server() -> Result<Self, ServiceFailure> {
        let security = SecurityDescriptor::new(PIPE_SDDL)?;
        let attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: security.pointer,
            bInheritHandle: 0,
        };
        let name = wide(PIPE_NAME);
        // SAFETY：名称、属性和安全描述符在调用期间有效；只创建一个本地实例。
        let handle = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_MESSAGE
                    | PIPE_READMODE_MESSAGE
                    | PIPE_NOWAIT
                    | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                PIPE_BUFFER_BYTES,
                PIPE_BUFFER_BYTES,
                0,
                &attributes,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(ServiceFailure::last("ipc", "CreateNamedPipeW"));
        }
        Ok(Self {
            handle,
            server: true,
        })
    }

    pub(super) fn connect_server(
        &self,
        deadline: Instant,
        stop_requested: &AtomicBool,
    ) -> Result<(), ServiceFailure> {
        loop {
            if stop_requested.load(Ordering::Relaxed) {
                return Err(ServiceFailure::new("ipc", "service_stop_requested", 995));
            }
            // SAFETY：服务端句柄有效；非等待模式下调用不会无限阻塞。
            if unsafe { ConnectNamedPipe(self.handle, std::ptr::null_mut()) } != 0 {
                break;
            }
            let code = unsafe { GetLastError() };
            if code == ERROR_PIPE_CONNECTED {
                break;
            }
            if !matches!(code, ERROR_PIPE_LISTENING | ERROR_NO_DATA) {
                return Err(ServiceFailure::new("ipc", "ConnectNamedPipe", code));
            }
            if Instant::now() >= deadline {
                return Err(ServiceFailure::new("ipc", "ConnectNamedPipe.timeout", 1460));
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        let mode = PIPE_READMODE_MESSAGE | PIPE_WAIT;
        // SAFETY：连接成功后把服务端句柄恢复为阻塞消息模式；其余参数无需修改。
        if unsafe {
            SetNamedPipeHandleState(self.handle, &mode, std::ptr::null(), std::ptr::null())
        } == 0
        {
            return Err(ServiceFailure::last("ipc", "SetNamedPipeHandleState"));
        }
        Ok(())
    }

    pub(super) fn connect_client(deadline: Instant) -> Result<Self, ServiceFailure> {
        let name = wide(PIPE_NAME);
        loop {
            // SAFETY：只请求消息读写所需的明确权限，不请求创建管道实例权限。
            let handle = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    CLIENT_PIPE_ACCESS,
                    0,
                    std::ptr::null(),
                    OPEN_EXISTING,
                    0,
                    std::ptr::null_mut(),
                )
            };
            if handle != INVALID_HANDLE_VALUE {
                return Ok(Self {
                    handle,
                    server: false,
                });
            }
            if Instant::now() >= deadline {
                return Err(ServiceFailure::last("ipc", "CreateFileW.timeout"));
            }
            // SAFETY：名称有效，短时等待用于避免忙轮询。
            unsafe { WaitNamedPipeW(name.as_ptr(), 250) };
        }
    }

    pub(super) fn handle(&self) -> HANDLE {
        self.handle
    }

    pub(super) fn write_message<T: Serialize>(&self, value: &T) -> Result<(), ServiceFailure> {
        let payload = serde_json::to_vec(value)
            .map_err(|_| ServiceFailure::new("ipc", "serde_json.serialize", 13))?;
        if payload.len() > PIPE_BUFFER_BYTES as usize {
            return Err(ServiceFailure::new("ipc", "message_too_large", 122));
        }
        let mut written = 0;
        // SAFETY：句柄有效，payload 在同步写入期间保持有效。
        let succeeded = unsafe {
            WriteFile(
                self.handle,
                payload.as_ptr(),
                payload.len() as u32,
                &mut written,
                std::ptr::null_mut(),
            )
        };
        if succeeded == 0 || written != payload.len() as u32 {
            return Err(ServiceFailure::last("ipc", "WriteFile"));
        }
        Ok(())
    }

    pub(super) fn read_message_until<T: DeserializeOwned>(
        &self,
        deadline: Instant,
        stop_requested: Option<&AtomicBool>,
    ) -> Result<T, ServiceFailure> {
        loop {
            if stop_requested.is_some_and(|stop| stop.load(Ordering::Relaxed)) {
                return Err(ServiceFailure::new("ipc", "service_stop_requested", 995));
            }
            let mut available = 0;
            // SAFETY：PeekNamedPipe 不移除数据；只查询当前可读字节数。
            let peeked = unsafe {
                PeekNamedPipe(
                    self.handle,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    &mut available,
                    std::ptr::null_mut(),
                )
            };
            if peeked == 0 {
                return Err(ServiceFailure::last("ipc", "PeekNamedPipe"));
            }
            if available > PIPE_BUFFER_BYTES {
                return Err(ServiceFailure::new("ipc", "message_too_large", 122));
            }
            if available > 0 {
                let mut payload = vec![0_u8; available as usize];
                let mut read = 0;
                // SAFETY：缓冲区大小等于 PeekNamedPipe 报告的消息可读长度。
                let succeeded = unsafe {
                    ReadFile(
                        self.handle,
                        payload.as_mut_ptr(),
                        payload.len() as u32,
                        &mut read,
                        std::ptr::null_mut(),
                    )
                };
                if succeeded == 0 {
                    return Err(ServiceFailure::last("ipc", "ReadFile"));
                }
                payload.truncate(read as usize);
                return serde_json::from_slice(&payload)
                    .map_err(|_| ServiceFailure::new("ipc", "serde_json.deserialize", 13));
            }
            if Instant::now() >= deadline {
                return Err(ServiceFailure::new("ipc", "ReadFile.timeout", 1460));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Pipe {
    fn drop(&mut self) {
        if self.server {
            // SAFETY：只对服务端句柄执行断开；失败表示客户端已自行断开。
            unsafe { DisconnectNamedPipe(self.handle) };
        }
        // SAFETY：句柄由 CreateNamedPipeW 或 CreateFileW 返回，只关闭一次。
        unsafe { CloseHandle(self.handle) };
    }
}

struct SecurityDescriptor {
    pointer: PSECURITY_DESCRIPTOR,
}

impl SecurityDescriptor {
    fn new(sddl: &str) -> Result<Self, ServiceFailure> {
        let sddl = wide(sddl);
        let mut pointer = std::ptr::null_mut();
        // SAFETY：输入是以 NUL 结尾的固定 SDDL；系统分配返回的描述符。
        let converted = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut pointer,
                std::ptr::null_mut(),
            )
        };
        if converted == 0 {
            return Err(ServiceFailure::last(
                "ipc",
                "ConvertStringSecurityDescriptorToSecurityDescriptorW",
            ));
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

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_pipe_access_excludes_create_instance_right() {
        const FILE_CREATE_PIPE_INSTANCE: u32 = 0x0000_0004;

        assert_eq!(CLIENT_PIPE_ACCESS, GENERIC_READ | FILE_WRITE_DATA);
        assert_eq!(CLIENT_PIPE_ACCESS & FILE_CREATE_PIPE_INSTANCE, 0);
        assert!(PIPE_SDDL.contains("(A;;0x0012008b;;;IU)"));
    }

    #[test]
    fn pipe_security_descriptor_keeps_medium_integrity_boundary() {
        assert!(PIPE_SDDL.ends_with("S:(ML;;NW;;;ME)"));
        assert!(SecurityDescriptor::new(PIPE_SDDL).is_ok());
    }
}

use std::mem::size_of;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use serde::{Serialize, de::DeserializeOwned};
use storpulse_windows_service_contract::{MAX_FRAME_PAYLOAD_BYTES, decode_frame, encode_frame};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_BROKEN_PIPE, ERROR_FILE_NOT_FOUND, ERROR_NO_DATA, ERROR_PIPE_BUSY,
    ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING, GENERIC_READ, GetLastError, HANDLE,
    INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA,
    OPEN_EXISTING, PIPE_ACCESS_DUPLEX, ReadFile, WriteFile,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_NOWAIT,
    PIPE_REJECT_REMOTE_CLIENTS, PeekNamedPipe, SetNamedPipeHandleState, WaitNamedPipeW,
};

use crate::pipe_support::{PipeError, SecurityDescriptor, check_wait, wide};

pub const PRODUCT_PIPE_NAME: &str = r"\\.\pipe\StorPulse.Collector.v1";
const PIPE_BUFFER_BYTES: u32 = 65_536;
const POLL_INTERVAL: Duration = Duration::from_millis(20);
const CLIENT_PIPE_ACCESS: u32 = GENERIC_READ | FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES;
// LocalSystem 与管理员保留完全控制；交互用户只获得双向数据和模式切换权限。
const PIPE_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x0012018b;;;IU)S:(ML;;NW;;;ME)";

pub struct ProductPipe {
    handle: HANDLE,
    server: bool,
}

impl ProductPipe {
    pub fn create_server() -> Result<Self, PipeError> {
        let security = SecurityDescriptor::new(PIPE_SDDL)?;
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: security.pointer,
            bInheritHandle: 0,
        };
        let name = wide(PRODUCT_PIPE_NAME);
        // SAFETY：名称、属性和安全描述符在调用期间有效；只创建一个本地字节流实例。
        let handle = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                PIPE_BUFFER_BYTES,
                PIPE_BUFFER_BYTES,
                0,
                &attributes,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(PipeError::last("create_server"));
        }
        Ok(Self {
            handle,
            server: true,
        })
    }

    pub fn connect_server(
        &self,
        deadline: Instant,
        stop_requested: &AtomicBool,
    ) -> Result<(), PipeError> {
        loop {
            check_wait("connect_server", deadline, Some(stop_requested))?;
            // SAFETY：服务端句柄有效，非等待模式不会无限阻塞。
            if unsafe { ConnectNamedPipe(self.handle, std::ptr::null_mut()) } != 0 {
                return Ok(());
            }
            let code = unsafe { GetLastError() };
            if code == ERROR_PIPE_CONNECTED {
                return Ok(());
            }
            if !matches!(code, ERROR_PIPE_LISTENING | ERROR_NO_DATA) {
                return Err(PipeError::native("connect_server", code));
            }
            std::thread::sleep(POLL_INTERVAL);
        }
    }

    pub fn connect_client(
        deadline: Instant,
        stop_requested: Option<&AtomicBool>,
    ) -> Result<Self, PipeError> {
        let name = wide(PRODUCT_PIPE_NAME);
        loop {
            check_wait("connect_client", deadline, stop_requested)?;
            // SAFETY：只请求数据读写和读取模式切换权限，不请求创建管道实例权限。
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
                let mode = PIPE_NOWAIT;
                // SAFETY：客户端句柄有效，只切换为非等待字节读取模式。
                if unsafe {
                    SetNamedPipeHandleState(handle, &mode, std::ptr::null(), std::ptr::null())
                } == 0
                {
                    let error = PipeError::last("set_client_mode");
                    // SAFETY：句柄由 CreateFileW 返回，失败路径只关闭一次。
                    unsafe { CloseHandle(handle) };
                    return Err(error);
                }
                return Ok(Self {
                    handle,
                    server: false,
                });
            }
            let code = unsafe { GetLastError() };
            if !matches!(code, ERROR_FILE_NOT_FOUND | ERROR_PIPE_BUSY) {
                return Err(PipeError::native("connect_client", code));
            }
            // SAFETY：名称有效，短时等待用于避免忙轮询。
            unsafe { WaitNamedPipeW(name.as_ptr(), POLL_INTERVAL.as_millis() as u32) };
        }
    }

    pub fn handle(&self) -> HANDLE {
        self.handle
    }

    pub fn data_available(&self) -> Result<bool, PipeError> {
        let mut available = 0;
        // SAFETY：句柄有效；PeekNamedPipe 不消费数据，只返回当前可读字节数。
        if unsafe {
            PeekNamedPipe(
                self.handle,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(PipeError::last("peek_available"));
        }
        Ok(available > 0)
    }

    pub fn write_message_until<T: Serialize>(
        &self,
        value: &T,
        deadline: Instant,
        stop_requested: Option<&AtomicBool>,
    ) -> Result<(), PipeError> {
        let frame = encode_frame(value).map_err(|_| PipeError::invalid_frame("encode_frame"))?;
        self.write_all(&frame, deadline, stop_requested)
    }

    pub fn read_message_until<T: DeserializeOwned>(
        &self,
        deadline: Instant,
        stop_requested: Option<&AtomicBool>,
    ) -> Result<T, PipeError> {
        let mut header = [0_u8; size_of::<u32>()];
        self.read_exact(&mut header, deadline, stop_requested)?;
        let payload_length = u32::from_le_bytes(header) as usize;
        if payload_length > MAX_FRAME_PAYLOAD_BYTES {
            return Err(PipeError::invalid_frame("frame_too_large"));
        }
        let mut frame = vec![0_u8; header.len() + payload_length];
        frame[..header.len()].copy_from_slice(&header);
        self.read_exact(&mut frame[header.len()..], deadline, stop_requested)?;
        decode_frame(&frame).map_err(|_| PipeError::invalid_frame("decode_frame"))
    }

    fn read_exact(
        &self,
        output: &mut [u8],
        deadline: Instant,
        stop_requested: Option<&AtomicBool>,
    ) -> Result<(), PipeError> {
        let mut offset = 0;
        while offset < output.len() {
            check_wait("read_frame", deadline, stop_requested)?;
            let mut available = 0;
            // SAFETY：句柄有效；PeekNamedPipe 不消费数据。
            if unsafe {
                PeekNamedPipe(
                    self.handle,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    &mut available,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(PipeError::last("peek_frame"));
            }
            if available == 0 {
                std::thread::sleep(POLL_INTERVAL);
                continue;
            }
            let wanted = (output.len() - offset).min(available as usize);
            let mut read = 0;
            // SAFETY：输出切片至少包含 wanted 字节，句柄处于非等待字节模式。
            if unsafe {
                ReadFile(
                    self.handle,
                    output[offset..].as_mut_ptr(),
                    wanted as u32,
                    &mut read,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                let code = unsafe { GetLastError() };
                if code == ERROR_NO_DATA {
                    continue;
                }
                return Err(PipeError::native("read_frame", code));
            }
            if read == 0 {
                return Err(PipeError::native("read_frame", ERROR_BROKEN_PIPE));
            }
            offset += read as usize;
        }
        Ok(())
    }

    fn write_all(
        &self,
        input: &[u8],
        deadline: Instant,
        stop_requested: Option<&AtomicBool>,
    ) -> Result<(), PipeError> {
        let mut offset = 0;
        while offset < input.len() {
            check_wait("write_frame", deadline, stop_requested)?;
            let wanted = (input.len() - offset).min(PIPE_BUFFER_BYTES as usize);
            let mut written = 0;
            // SAFETY：输入切片至少包含 wanted 字节，句柄处于非等待模式。
            if unsafe {
                WriteFile(
                    self.handle,
                    input[offset..].as_ptr(),
                    wanted as u32,
                    &mut written,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                let code = unsafe { GetLastError() };
                if code == ERROR_NO_DATA {
                    std::thread::sleep(POLL_INTERVAL);
                    continue;
                }
                return Err(PipeError::native("write_frame", code));
            }
            if written == 0 {
                std::thread::sleep(POLL_INTERVAL);
                continue;
            }
            offset += written as usize;
        }
        Ok(())
    }
}

impl Drop for ProductPipe {
    fn drop(&mut self) {
        if self.server {
            // SAFETY：只对服务端句柄断开；失败表示客户端已自行断开。
            unsafe { DisconnectNamedPipe(self.handle) };
        }
        // SAFETY：句柄由 CreateNamedPipeW 或 CreateFileW 返回，只关闭一次。
        unsafe { CloseHandle(self.handle) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_pipe_is_distinct_and_local_only() {
        assert_eq!(PRODUCT_PIPE_NAME, r"\\.\pipe\StorPulse.Collector.v1");
        assert!(PIPE_SDDL.contains("(A;;0x0012018b;;;IU)"));
        assert!(PIPE_SDDL.ends_with("S:(ML;;NW;;;ME)"));
    }

    #[test]
    fn client_access_cannot_create_pipe_instances() {
        const FILE_CREATE_PIPE_INSTANCE: u32 = 0x0000_0004;

        assert_eq!(
            CLIENT_PIPE_ACCESS,
            GENERIC_READ | FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES
        );
        assert_eq!(CLIENT_PIPE_ACCESS & FILE_CREATE_PIPE_INSTANCE, 0);
    }
}

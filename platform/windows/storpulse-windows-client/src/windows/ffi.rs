use std::mem::ManuallyDrop;
use std::ptr;
use std::slice;
use std::sync::Mutex;
use std::time::Instant;

use serde::Serialize;

use crate::SafeFailure;

use super::{ClientError, MESSAGE_TIMEOUT};

mod session_state;

use session_state::SessionState;

pub const SP_WINDOWS_STATUS_OK: i32 = 0;
pub const SP_WINDOWS_STATUS_INVALID_HANDLE: i32 = 1;
pub const SP_WINDOWS_STATUS_INVALID_INPUT: i32 = 2;
pub const SP_WINDOWS_STATUS_INVALID_STATE: i32 = 3;
pub const SP_WINDOWS_STATUS_COLLECTOR_ERROR: i32 = 4;
pub const SP_WINDOWS_STATUS_INTERNAL_ERROR: i32 = 5;

#[repr(C)]
pub struct SpWindowsBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub capacity: usize,
    pub status: i32,
}

pub struct SpWindowsSession {
    state: Mutex<SessionState>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LastError<'a> {
    failure: Option<&'a SafeFailure>,
}

#[unsafe(no_mangle)]
pub extern "C" fn sp_windows_session_create() -> *mut SpWindowsSession {
    Box::into_raw(Box::new(SpWindowsSession {
        state: Mutex::new(SessionState::new()),
    }))
}

/// # Safety
/// `handle` 必须来自 `sp_windows_session_create`，且只能销毁一次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_windows_session_destroy(handle: *mut SpWindowsSession) {
    if !handle.is_null() {
        // 安全：调用者遵守本函数的所有权约定。
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// # Safety
/// `handle` 必须有效；`run_id` 在 `length` 范围内必须可读。
/// 同一句柄的开始、接收和停止调用必须串行执行。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_windows_session_start(
    handle: *mut SpWindowsSession,
    run_id: *const u8,
    length: usize,
) -> i32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return SP_WINDOWS_STATUS_INVALID_HANDLE;
    };
    let run_id = match unsafe { read_run_id(run_id, length) } {
        Ok(value) => value,
        Err(()) => {
            return record_locked_error(
                handle,
                SP_WINDOWS_STATUS_INVALID_INPUT,
                ClientError::new("input", "invalid_run_id", None),
            );
        }
    };
    let mut state = match handle.state.lock() {
        Ok(state) => state,
        Err(_) => return SP_WINDOWS_STATUS_INTERNAL_ERROR,
    };
    if state.is_started() {
        return record_error(
            &mut state,
            SP_WINDOWS_STATUS_INVALID_STATE,
            ClientError::new("lifecycle", "session_already_started", None),
        );
    }

    match state.start(run_id) {
        Ok(()) => {
            state.clear_error();
            SP_WINDOWS_STATUS_OK
        }
        Err(error) => record_error(&mut state, SP_WINDOWS_STATUS_COLLECTOR_ERROR, error),
    }
}

/// # Safety
/// `handle` 必须是有效且尚未销毁的句柄；同一句柄的调用必须串行执行。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_windows_session_next_snapshot_json(
    handle: *mut SpWindowsSession,
) -> SpWindowsBuffer {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return empty_buffer(SP_WINDOWS_STATUS_INVALID_HANDLE);
    };
    let mut state = match handle.state.lock() {
        Ok(state) => state,
        Err(_) => return empty_buffer(SP_WINDOWS_STATUS_INTERNAL_ERROR),
    };
    let Some(product) = state.product_mut() else {
        record_error(
            &mut state,
            SP_WINDOWS_STATUS_INVALID_STATE,
            ClientError::new("lifecycle", "session_not_started", None),
        );
        return empty_buffer(SP_WINDOWS_STATUS_INVALID_STATE);
    };
    match product.receive_snapshot(Instant::now() + MESSAGE_TIMEOUT) {
        Ok((_sequence, snapshot)) => encode_result(&mut state, &snapshot),
        Err(error) => {
            record_error(&mut state, SP_WINDOWS_STATUS_COLLECTOR_ERROR, error);
            empty_buffer(SP_WINDOWS_STATUS_COLLECTOR_ERROR)
        }
    }
}

/// # Safety
/// `handle` 必须是有效且尚未销毁的句柄；同一句柄的调用必须串行执行。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_windows_session_stop_json(
    handle: *mut SpWindowsSession,
) -> SpWindowsBuffer {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return empty_buffer(SP_WINDOWS_STATUS_INVALID_HANDLE);
    };
    let mut state = match handle.state.lock() {
        Ok(state) => state,
        Err(_) => return empty_buffer(SP_WINDOWS_STATUS_INTERNAL_ERROR),
    };
    if !state.has_product() {
        record_error(
            &mut state,
            SP_WINDOWS_STATUS_INVALID_STATE,
            ClientError::new("lifecycle", "session_not_started", None),
        );
        return empty_buffer(SP_WINDOWS_STATUS_INVALID_STATE);
    }
    match state.stop() {
        Ok(result) => encode_result(&mut state, &result),
        Err(error) => {
            record_error(&mut state, SP_WINDOWS_STATUS_COLLECTOR_ERROR, error);
            empty_buffer(SP_WINDOWS_STATUS_COLLECTOR_ERROR)
        }
    }
}

/// # Safety
/// `handle` 必须是有效且尚未销毁的句柄。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_windows_session_last_error_json(
    handle: *mut SpWindowsSession,
) -> SpWindowsBuffer {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return empty_buffer(SP_WINDOWS_STATUS_INVALID_HANDLE);
    };
    let state = match handle.state.lock() {
        Ok(state) => state,
        Err(_) => return empty_buffer(SP_WINDOWS_STATUS_INTERNAL_ERROR),
    };
    match serde_json::to_vec(&LastError {
        failure: state.last_error(),
    }) {
        Ok(bytes) => into_buffer(bytes, SP_WINDOWS_STATUS_OK),
        Err(_) => empty_buffer(SP_WINDOWS_STATUS_INTERNAL_ERROR),
    }
}

/// # Safety
/// `buffer` 必须来自本库返回值，且只能释放一次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_windows_buffer_free(buffer: SpWindowsBuffer) {
    if !buffer.ptr.is_null() && buffer.capacity > 0 {
        // 安全：指针、长度和容量来自 `into_buffer`。
        unsafe { drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.capacity)) };
    }
}

unsafe fn read_run_id(pointer: *const u8, length: usize) -> Result<String, ()> {
    if pointer.is_null() || length == 0 || length > 128 {
        return Err(());
    }
    // 安全：调用者承诺输入指针在指定长度内有效。
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    if !bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(());
    }
    String::from_utf8(bytes.to_vec()).map_err(|_| ())
}

fn record_locked_error(handle: &SpWindowsSession, status: i32, error: ClientError) -> i32 {
    let Ok(mut state) = handle.state.lock() else {
        return SP_WINDOWS_STATUS_INTERNAL_ERROR;
    };
    record_error(&mut state, status, error)
}

fn record_error(state: &mut SessionState, status: i32, error: ClientError) -> i32 {
    state.record_error(error.safe_failure());
    status
}

fn encode_result<T: Serialize>(state: &mut SessionState, value: &T) -> SpWindowsBuffer {
    match serde_json::to_vec(value) {
        Ok(bytes) => {
            state.clear_error();
            into_buffer(bytes, SP_WINDOWS_STATUS_OK)
        }
        Err(_) => {
            record_error(
                state,
                SP_WINDOWS_STATUS_INTERNAL_ERROR,
                ClientError::new("serialization", "result_encoding_failed", None),
            );
            empty_buffer(SP_WINDOWS_STATUS_INTERNAL_ERROR)
        }
    }
}

fn empty_buffer(status: i32) -> SpWindowsBuffer {
    SpWindowsBuffer {
        ptr: ptr::null_mut(),
        len: 0,
        capacity: 0,
        status,
    }
}

fn into_buffer(bytes: Vec<u8>, status: i32) -> SpWindowsBuffer {
    if bytes.is_empty() {
        return empty_buffer(status);
    }
    let mut bytes = ManuallyDrop::new(bytes);
    SpWindowsBuffer {
        ptr: bytes.as_mut_ptr(),
        len: bytes.len(),
        capacity: bytes.capacity(),
        status,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_id只接受受限_ascii字符() {
        // 安全：测试输入缓冲区在调用期间有效。
        assert_eq!(
            unsafe { read_run_id(b"stage2c-01".as_ptr(), 10) }.unwrap(),
            "stage2c-01"
        );
        // 安全：测试输入缓冲区在调用期间有效。
        assert!(unsafe { read_run_id(b"../machine".as_ptr(), 10) }.is_err());
    }

    #[test]
    fn 返回缓冲区可由配对函数释放() {
        let buffer = into_buffer(vec![1, 2, 3], SP_WINDOWS_STATUS_OK);
        assert_eq!(buffer.len, 3);
        // 安全：缓冲区来自 `into_buffer`，且只释放一次。
        unsafe { sp_windows_buffer_free(buffer) };
    }
}

use std::{mem::ManuallyDrop, ptr, slice, sync::Mutex};

use serde_json::json;
use storpulse_core::{Engine, EngineCommand, model::RawSnapshot};

pub const SP_STATUS_OK: i32 = 0;
pub const SP_STATUS_INVALID_HANDLE: i32 = 1;
pub const SP_STATUS_INVALID_INPUT: i32 = 2;
pub const SP_STATUS_ENGINE_ERROR: i32 = 3;
pub const SP_STATUS_INTERNAL_ERROR: i32 = 4;

#[repr(C)]
pub struct SpBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub capacity: usize,
    pub status: i32,
}

pub struct SpEngine {
    engine: Mutex<Engine>,
    last_error: Mutex<Option<String>>,
}

#[unsafe(no_mangle)]
pub extern "C" fn sp_engine_create() -> *mut SpEngine {
    Box::into_raw(Box::new(SpEngine {
        engine: Mutex::new(Engine::default()),
        last_error: Mutex::new(None),
    }))
}

/// # Safety
/// `engine` 必须来自 `sp_engine_create`，且只能销毁一次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_engine_destroy(engine: *mut SpEngine) {
    if !engine.is_null() {
        // 安全：调用者遵守本函数的所有权约定。
        unsafe { drop(Box::from_raw(engine)) };
    }
}

/// # Safety
/// `engine` 必须是有效句柄；`json` 在 `length` 范围内必须可读。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_engine_ingest_json(
    engine: *mut SpEngine,
    json: *const u8,
    length: usize,
) -> i32 {
    let Some(handle) = (unsafe { engine.as_ref() }) else {
        return SP_STATUS_INVALID_HANDLE;
    };
    let bytes = match unsafe { input_bytes(json, length) } {
        Ok(bytes) => bytes,
        Err(message) => return record_error(handle, SP_STATUS_INVALID_INPUT, message),
    };
    let snapshot: RawSnapshot = match serde_json::from_slice(bytes) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            return record_error(
                handle,
                SP_STATUS_INVALID_INPUT,
                format!("原始快照 JSON 无效：{error}"),
            );
        }
    };
    let mut engine = match handle.engine.lock() {
        Ok(engine) => engine,
        Err(_) => return record_error(handle, SP_STATUS_INTERNAL_ERROR, "引擎锁已损坏"),
    };
    match engine.ingest(snapshot) {
        Ok(_) => {
            clear_error(handle);
            SP_STATUS_OK
        }
        Err(error) => record_error(handle, SP_STATUS_ENGINE_ERROR, error.to_string()),
    }
}

/// # Safety
/// `engine` 必须是有效且尚未销毁的句柄。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_engine_snapshot_json(
    engine: *mut SpEngine,
    monotonic_nanoseconds: u64,
) -> SpBuffer {
    let Some(handle) = (unsafe { engine.as_ref() }) else {
        return empty_buffer(SP_STATUS_INVALID_HANDLE);
    };
    let engine = match handle.engine.lock() {
        Ok(engine) => engine,
        Err(_) => {
            record_error(handle, SP_STATUS_INTERNAL_ERROR, "引擎锁已损坏");
            return empty_buffer(SP_STATUS_INTERNAL_ERROR);
        }
    };
    match engine.snapshot_at(monotonic_nanoseconds) {
        Ok(snapshot) => encode_result(handle, &snapshot),
        Err(error) => {
            record_error(handle, SP_STATUS_ENGINE_ERROR, error.to_string());
            empty_buffer(SP_STATUS_ENGINE_ERROR)
        }
    }
}

/// # Safety
/// `engine` 必须是有效句柄；`json` 在 `length` 范围内必须可读。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_engine_command_json(
    engine: *mut SpEngine,
    json: *const u8,
    length: usize,
) -> SpBuffer {
    let Some(handle) = (unsafe { engine.as_ref() }) else {
        return empty_buffer(SP_STATUS_INVALID_HANDLE);
    };
    let bytes = match unsafe { input_bytes(json, length) } {
        Ok(bytes) => bytes,
        Err(message) => {
            record_error(handle, SP_STATUS_INVALID_INPUT, message);
            return empty_buffer(SP_STATUS_INVALID_INPUT);
        }
    };
    let command: EngineCommand = match serde_json::from_slice(bytes) {
        Ok(command) => command,
        Err(error) => {
            record_error(
                handle,
                SP_STATUS_INVALID_INPUT,
                format!("用户命令 JSON 无效：{error}"),
            );
            return empty_buffer(SP_STATUS_INVALID_INPUT);
        }
    };
    let mut engine = match handle.engine.lock() {
        Ok(engine) => engine,
        Err(_) => {
            record_error(handle, SP_STATUS_INTERNAL_ERROR, "引擎锁已损坏");
            return empty_buffer(SP_STATUS_INTERNAL_ERROR);
        }
    };
    match engine.execute(command) {
        Ok(result) => encode_result(handle, &result),
        Err(error) => {
            record_error(handle, SP_STATUS_ENGINE_ERROR, error.to_string());
            empty_buffer(SP_STATUS_ENGINE_ERROR)
        }
    }
}

/// # Safety
/// `engine` 必须是有效且尚未销毁的句柄。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_engine_last_error_json(engine: *mut SpEngine) -> SpBuffer {
    let Some(handle) = (unsafe { engine.as_ref() }) else {
        return empty_buffer(SP_STATUS_INVALID_HANDLE);
    };
    let message = handle
        .last_error
        .lock()
        .ok()
        .and_then(|value| value.clone())
        .unwrap_or_default();
    into_buffer(
        serde_json::to_vec(&json!({ "message": message })).unwrap_or_default(),
        SP_STATUS_OK,
    )
}

/// # Safety
/// `buffer` 必须来自本库返回值，且只能释放一次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_buffer_free(buffer: SpBuffer) {
    if !buffer.ptr.is_null() && buffer.capacity > 0 {
        // 安全：指针、长度和容量来自 `into_buffer`。
        unsafe { drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.capacity)) };
    }
}

unsafe fn input_bytes<'a>(json: *const u8, length: usize) -> Result<&'a [u8], &'static str> {
    if json.is_null() || length == 0 {
        return Err("输入 JSON 不能为空");
    }
    // 安全：调用者承诺输入指针在指定长度内有效。
    Ok(unsafe { slice::from_raw_parts(json, length) })
}

fn encode_result<T: serde::Serialize>(handle: &SpEngine, value: &T) -> SpBuffer {
    match serde_json::to_vec(value) {
        Ok(bytes) => {
            clear_error(handle);
            into_buffer(bytes, SP_STATUS_OK)
        }
        Err(error) => {
            record_error(
                handle,
                SP_STATUS_INTERNAL_ERROR,
                format!("返回 JSON 编码失败：{error}"),
            );
            empty_buffer(SP_STATUS_INTERNAL_ERROR)
        }
    }
}

fn record_error(handle: &SpEngine, status: i32, message: impl Into<String>) -> i32 {
    if let Ok(mut error) = handle.last_error.lock() {
        *error = Some(message.into());
    }
    status
}

fn clear_error(handle: &SpEngine) {
    if let Ok(mut error) = handle.last_error.lock() {
        *error = None;
    }
}

fn empty_buffer(status: i32) -> SpBuffer {
    SpBuffer {
        ptr: ptr::null_mut(),
        len: 0,
        capacity: 0,
        status,
    }
}

fn into_buffer(bytes: Vec<u8>, status: i32) -> SpBuffer {
    if bytes.is_empty() {
        return empty_buffer(status);
    }
    let mut bytes = ManuallyDrop::new(bytes);
    SpBuffer {
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
    fn ffi_ingests_snapshot_and_returns_owned_json_buffer() {
        let handle = sp_engine_create();
        let snapshot = br#"{
          "schemaVersion":2,"capturedAt":"2026-07-30T10:00:00Z",
          "monotonicNanoseconds":1000000000,"metricSource":"fixture",
          "metricScope":["storage_process"],"freshness":"fresh",
          "completeness":"partial","processes":[],"devices":[],
          "summary":{"discoveredProcesses":0,"readableProcesses":0,
          "restrictedProcesses":0,"exitedProcesses":0,"deviceCount":0,
          "collectionDurationNanoseconds":1}}
        "#;

        // 安全：测试句柄和输入缓冲区在调用期间有效。
        let status = unsafe { sp_engine_ingest_json(handle, snapshot.as_ptr(), snapshot.len()) };
        assert_eq!(status, SP_STATUS_OK);

        // 安全：测试句柄尚未销毁。
        let buffer = unsafe { sp_engine_snapshot_json(handle, 1_000_000_001) };
        assert_eq!(buffer.status, SP_STATUS_OK);
        // 安全：返回缓冲区在释放前有效。
        let output = unsafe { slice::from_raw_parts(buffer.ptr, buffer.len) };
        let value: serde_json::Value = serde_json::from_slice(output).unwrap();
        assert_eq!(value["schemaVersion"], 2);

        // 安全：缓冲区和句柄均只释放一次。
        unsafe {
            sp_buffer_free(buffer);
            sp_engine_destroy(handle);
        }
    }

    #[test]
    fn ffi_rejects_empty_input_without_panicking() {
        let handle = sp_engine_create();
        // 安全：空指针与零长度用于验证输入拒绝路径。
        let status = unsafe { sp_engine_ingest_json(handle, ptr::null(), 0) };
        assert_eq!(status, SP_STATUS_INVALID_INPUT);
        // 安全：句柄只销毁一次。
        unsafe { sp_engine_destroy(handle) };
    }
}

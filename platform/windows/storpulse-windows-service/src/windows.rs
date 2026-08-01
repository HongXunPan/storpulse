use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

use storpulse_windows_service_contract::PRODUCT_SERVICE_NAME;
use storpulse_windows_service_runtime::windows::{ServiceRunError, run_single_session_with_ready};
use windows_sys::Win32::Foundation::{
    ERROR_CALL_NOT_IMPLEMENTED, ERROR_INVALID_PARAMETER, ERROR_SERVICE_SPECIFIC_ERROR,
    GetLastError, NO_ERROR,
};
use windows_sys::Win32::System::Services::{
    RegisterServiceCtrlHandlerExW, SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP,
    SERVICE_CONTROL_INTERROGATE, SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP, SERVICE_RUNNING,
    SERVICE_START_PENDING, SERVICE_STATUS, SERVICE_STATUS_HANDLE, SERVICE_STOP_PENDING,
    SERVICE_STOPPED, SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS, SetServiceStatus,
    StartServiceCtrlDispatcherW,
};

use crate::start_argument::parse_service_arguments;

const START_WAIT_HINT_MILLISECONDS: u32 = 15_000;
const STOP_WAIT_HINT_MILLISECONDS: u32 = 5_000;
const MAX_SERVICE_ARGUMENTS: u32 = 8;
const MAX_ARGUMENT_UTF16_UNITS: usize = 256;

static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);
static STATUS_HANDLE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

pub(crate) fn run_dispatcher() -> Result<(), u32> {
    let mut service_name = wide(PRODUCT_SERVICE_NAME);
    let table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: service_name.as_mut_ptr(),
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW::default(),
    ];
    // SAFETY：服务表以空项终止，名称缓冲区在阻塞调用期间保持有效。
    if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 {
        return Err(unsafe { GetLastError() });
    }
    Ok(())
}

unsafe extern "system" fn service_main(argument_count: u32, arguments: *mut *mut u16) {
    STOP_REQUESTED.store(false, Ordering::Release);
    let service_name = wide(PRODUCT_SERVICE_NAME);
    // SAFETY：SCM 在 ServiceMain 生命周期内提供有效服务名和回调入口。
    let handle = unsafe {
        RegisterServiceCtrlHandlerExW(
            service_name.as_ptr(),
            Some(service_control_handler),
            std::ptr::null(),
        )
    };
    if handle.is_null() {
        return;
    }
    STATUS_HANDLE.store(handle, Ordering::Release);
    if report_status(
        SERVICE_START_PENDING,
        NO_ERROR,
        0,
        START_WAIT_HINT_MILLISECONDS,
    )
    .is_err()
    {
        STATUS_HANDLE.store(std::ptr::null_mut(), Ordering::Release);
        return;
    }

    // SAFETY：参数由 SCM 在 ServiceMain 生命周期内提供，只同步转换为受限字符串。
    let result = unsafe { service_arguments(argument_count, arguments) }
        .ok()
        .and_then(|values| parse_service_arguments(&values).ok())
        .ok_or(ServiceMainFailure::InvalidStartArgument)
        .and_then(run_service);

    let controlled_stop = STOP_REQUESTED.load(Ordering::Acquire)
        && result
            .as_ref()
            .err()
            .is_some_and(ServiceMainFailure::is_stop_requested);
    let _ = report_status(
        SERVICE_STOP_PENDING,
        NO_ERROR,
        0,
        STOP_WAIT_HINT_MILLISECONDS,
    );
    if result.is_ok() || controlled_stop {
        let _ = report_status(SERVICE_STOPPED, NO_ERROR, 0, 0);
    } else if let Err(error) = result {
        let _ = report_status(
            SERVICE_STOPPED,
            ERROR_SERVICE_SPECIFIC_ERROR,
            error.service_exit_code(),
            0,
        );
    }
    STATUS_HANDLE.store(std::ptr::null_mut(), Ordering::Release);
}

fn run_service(expected_nonce: String) -> Result<(), ServiceMainFailure> {
    run_single_session_with_ready(&expected_nonce, &STOP_REQUESTED, || {
        report_status(SERVICE_RUNNING, NO_ERROR, 0, 0)
    })
    .map(|_| ())
    .map_err(ServiceMainFailure::Runtime)
}

unsafe extern "system" fn service_control_handler(
    control: u32,
    _event_type: u32,
    _event_data: *mut c_void,
    _context: *mut c_void,
) -> u32 {
    match control {
        SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN => {
            if !STOP_REQUESTED.swap(true, Ordering::AcqRel) {
                let _ = report_status(
                    SERVICE_STOP_PENDING,
                    NO_ERROR,
                    0,
                    STOP_WAIT_HINT_MILLISECONDS,
                );
            }
            NO_ERROR
        }
        SERVICE_CONTROL_INTERROGATE => NO_ERROR,
        _ => ERROR_CALL_NOT_IMPLEMENTED,
    }
}

fn report_status(
    state: u32,
    exit_code: u32,
    service_exit_code: u32,
    wait_hint: u32,
) -> Result<(), u32> {
    let handle: SERVICE_STATUS_HANDLE = STATUS_HANDLE.load(Ordering::Acquire);
    if handle.is_null() {
        return Err(6);
    }
    let pending = matches!(state, SERVICE_START_PENDING | SERVICE_STOP_PENDING);
    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: if state == SERVICE_RUNNING {
            SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
        } else {
            0
        },
        dwWin32ExitCode: exit_code,
        dwServiceSpecificExitCode: service_exit_code,
        dwCheckPoint: u32::from(pending),
        dwWaitHint: wait_hint,
    };
    // SAFETY：状态句柄由 RegisterServiceCtrlHandlerExW 返回，结构体在调用期间有效。
    if unsafe { SetServiceStatus(handle, &status) } == 0 {
        return Err(unsafe { GetLastError() });
    }
    Ok(())
}

unsafe fn service_arguments(
    argument_count: u32,
    arguments: *mut *mut u16,
) -> Result<Vec<String>, ()> {
    if argument_count == 0 || argument_count > MAX_SERVICE_ARGUMENTS || arguments.is_null() {
        return Err(());
    }
    let mut values = Vec::with_capacity(argument_count as usize);
    for index in 0..argument_count as usize {
        // SAFETY：SCM 保证参数数组包含 argument_count 个字符串指针。
        let pointer = unsafe { *arguments.add(index) };
        // SAFETY：每个 SCM 参数都是以 NUL 结尾的 UTF-16 字符串。
        values.push(unsafe { wide_pointer_to_string(pointer) }.ok_or(())?);
    }
    Ok(values)
}

unsafe fn wide_pointer_to_string(pointer: *const u16) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    let length = (0..MAX_ARGUMENT_UTF16_UNITS)
        // SAFETY：SCM 参数在 ServiceMain 生命周期内有效；扫描有严格上限。
        .find(|index| unsafe { *pointer.add(*index) } == 0)?;
    // SAFETY：扫描已经确认 length 个 UTF-16 单元位于终止符之前。
    String::from_utf16(unsafe { std::slice::from_raw_parts(pointer, length) }).ok()
}

enum ServiceMainFailure {
    InvalidStartArgument,
    Runtime(ServiceRunError),
}

impl ServiceMainFailure {
    fn is_stop_requested(&self) -> bool {
        matches!(self, Self::Runtime(error) if error.is_stop_requested())
    }

    fn service_exit_code(&self) -> u32 {
        match self {
            Self::InvalidStartArgument => ERROR_INVALID_PARAMETER,
            Self::Runtime(error) => error.native_code.filter(|code| *code != 0).unwrap_or(1),
        }
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{ERROR_SERVICE_SPECIFIC_ERROR, NO_ERROR};
use windows_sys::Win32::System::Services::{
    RegisterServiceCtrlHandlerExW, SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP,
    SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP, SERVICE_RUNNING, SERVICE_START_PENDING,
    SERVICE_STATUS, SERVICE_STATUS_HANDLE, SERVICE_STOP_PENDING, SERVICE_STOPPED,
    SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS, SetServiceStatus, StartServiceCtrlDispatcherW,
};

use crate::model::ServiceGateReport;

use super::super::{calculate_self_measurements, etw, process};
use super::failure_delivery::send_failure;
use super::identity::{current_process_is_local_system, inspect_pipe_client};
use super::protocol::{SCHEMA_VERSION, ServiceRequest, ServiceResponse};
use super::transport::Pipe;
use super::{SERVICE_ETW_SESSION_NAME, SERVICE_NAME, ServiceFailure, auth};

static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);
static STATUS_HANDLE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

pub(super) fn run_dispatcher() -> Result<(), ServiceFailure> {
    let mut service_name = wide(SERVICE_NAME);
    let table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: service_name.as_mut_ptr(),
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW::default(),
    ];
    // SAFETY：服务表以空项终止，名称缓冲区在阻塞调用期间保持有效。
    if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 {
        return Err(ServiceFailure::last(
            "service_runtime",
            "StartServiceCtrlDispatcherW",
        ));
    }
    Ok(())
}

unsafe extern "system" fn service_main(argument_count: u32, arguments: *mut *mut u16) {
    STOP_REQUESTED.store(false, Ordering::Relaxed);
    let service_name = wide(SERVICE_NAME);
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
    STATUS_HANDLE.store(handle, Ordering::Relaxed);
    set_status(SERVICE_START_PENDING, NO_ERROR, 0, 15_000);

    let result = service_nonce(argument_count, arguments).and_then(run_service);
    set_status(SERVICE_STOP_PENDING, NO_ERROR, 0, 3_000);
    match result {
        Ok(()) => set_status(SERVICE_STOPPED, NO_ERROR, 0, 0),
        Err(error) => set_status(SERVICE_STOPPED, ERROR_SERVICE_SPECIFIC_ERROR, error.code, 0),
    }
    STATUS_HANDLE.store(std::ptr::null_mut(), Ordering::Relaxed);
}

unsafe extern "system" fn service_control_handler(
    control: u32,
    _event_type: u32,
    _event_data: *mut c_void,
    _context: *mut c_void,
) -> u32 {
    if matches!(control, SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN) {
        STOP_REQUESTED.store(true, Ordering::Relaxed);
        set_status(SERVICE_STOP_PENDING, NO_ERROR, 0, 3_000);
    }
    NO_ERROR
}

fn run_service(expected_nonce: String) -> Result<(), ServiceFailure> {
    let service_local_system = current_process_is_local_system()?;
    if !service_local_system {
        return Err(ServiceFailure::new(
            "service_identity",
            "service_not_local_system",
            5,
        ));
    }

    let pipe = Pipe::create_server()?;
    set_status(SERVICE_RUNNING, NO_ERROR, 0, 0);
    pipe.connect_server(Instant::now() + Duration::from_secs(30), &STOP_REQUESTED)?;

    let begin_payload = pipe.read_payload_until(
        Instant::now() + Duration::from_secs(10),
        Some(&STOP_REQUESTED),
    )?;
    let begin = ServiceRequest::decode(&begin_payload)?;
    let (nonce, requested_process_id, duration_seconds) = match begin {
        ServiceRequest::Begin {
            schema_version,
            nonce,
            client_process_id,
            duration_seconds,
        } if schema_version == SCHEMA_VERSION && (5..=300).contains(&duration_seconds) => {
            (nonce, client_process_id, duration_seconds)
        }
        request => {
            let error = ServiceFailure::new(
                "protocol",
                if request.schema_version() == SCHEMA_VERSION {
                    "invalid_begin_request"
                } else {
                    "unsupported_schema"
                },
                87,
            );
            send_failure(&pipe, &error, &STOP_REQUESTED);
            return Err(error);
        }
    };

    let client = inspect_pipe_client(pipe.handle())?;
    let process_id_matched = client.process_id == requested_process_id;
    let authenticated = auth::nonce_matches(&expected_nonce, &nonce)
        && process_id_matched
        && client.elevated == Some(false);
    if !authenticated {
        let error = ServiceFailure::new("authentication", "client_rejected", 5);
        send_failure(&pipe, &error, &STOP_REQUESTED);
        return Err(error);
    }

    let service_process_id = std::process::id();
    let service_before = process::current_process().map_err(ServiceFailure::from_native)?;
    std::thread::sleep(Duration::from_secs(2));
    let service_idle = process::current_process().map_err(ServiceFailure::from_native)?;
    let trace_session = match etw::TraceSession::start_named(SERVICE_ETW_SESSION_NAME) {
        Ok(session) => session,
        Err(error) => {
            let failure = ServiceFailure::from_native(error);
            send_failure(&pipe, &failure, &STOP_REQUESTED);
            return Err(failure);
        }
    };

    pipe.write_message(&ServiceResponse::Ready {
        schema_version: SCHEMA_VERSION,
        service_process_id,
        service_local_system,
        client_process_id_matched: process_id_matched,
        client_elevated: client.elevated,
    })?;

    let finish_payload = pipe.read_payload_until(
        Instant::now() + Duration::from_secs(duration_seconds.saturating_add(30)),
        Some(&STOP_REQUESTED),
    );
    let finish = finish_payload.and_then(|payload| ServiceRequest::decode(&payload));
    let short_lived_processes = match finish {
        Ok(ServiceRequest::Finish {
            schema_version,
            short_lived_processes,
        }) if schema_version == SCHEMA_VERSION => Some(short_lived_processes),
        Ok(request) => {
            let error = ServiceFailure::new(
                "protocol",
                if request.schema_version() == SCHEMA_VERSION {
                    "invalid_finish_request"
                } else {
                    "unsupported_schema"
                },
                87,
            );
            send_failure(&pipe, &error, &STOP_REQUESTED);
            None
        }
        Err(_) => None,
    };

    let identities = short_lived_processes.as_deref().unwrap_or(&[]);
    let etw_report = trace_session.stop(client.process_id, identities);
    let service_after = process::current_process().map_err(ServiceFailure::from_native)?;

    if short_lived_processes.is_none() {
        return Ok(());
    }

    let service = ServiceGateReport {
        service_name: SERVICE_NAME.to_string(),
        service_process_id,
        service_local_system,
        client_process_id_matched: process_id_matched,
        client_elevated: client.elevated,
        client_authenticated: true,
        pipe_reject_remote_clients: true,
        service_stopped: false,
        disconnect_cleanup_test: false,
        service_self_measurements: calculate_self_measurements(
            &service_before,
            &service_idle,
            &service_after,
        ),
    };
    let completed = ServiceResponse::Completed {
        schema_version: SCHEMA_VERSION,
        etw: Box::new(etw_report),
        service,
    };
    if let Err(error) = completed.validate_round_trip() {
        send_failure(&pipe, &error, &STOP_REQUESTED);
        return Err(error);
    }
    pipe.write_message(&completed)?;

    let acknowledgement_payload = pipe.read_payload_until(
        Instant::now() + Duration::from_secs(10),
        Some(&STOP_REQUESTED),
    )?;
    let acknowledgement = ServiceRequest::decode(&acknowledgement_payload)?;
    match acknowledgement {
        ServiceRequest::Acknowledge { schema_version } if schema_version == SCHEMA_VERSION => {
            Ok(())
        }
        request => Err(ServiceFailure::new(
            "protocol",
            if request.schema_version() == SCHEMA_VERSION {
                "invalid_completion_acknowledgement"
            } else {
                "unsupported_schema"
            },
            87,
        )),
    }
}

fn service_nonce(argument_count: u32, arguments: *mut *mut u16) -> Result<String, ServiceFailure> {
    if argument_count < 2 || arguments.is_null() {
        return Err(ServiceFailure::new(
            "service_runtime",
            "missing_start_nonce",
            87,
        ));
    }
    // SAFETY：SCM 保证参数数组包含 argument_count 个以 NUL 结尾的字符串。
    let pointer = unsafe { *arguments.add((argument_count - 1) as usize) };
    let nonce = unsafe { wide_pointer_to_string(pointer) };
    if nonce.len() != 64 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ServiceFailure::new(
            "service_runtime",
            "invalid_start_nonce",
            87,
        ));
    }
    Ok(nonce)
}

unsafe fn wide_pointer_to_string(pointer: *const u16) -> String {
    if pointer.is_null() {
        return String::new();
    }
    let mut length = 0;
    // SAFETY：SCM 提供以 NUL 结尾的参数；限制最大长度避免异常参数无限扫描。
    while length < 256 && unsafe { *pointer.add(length) } != 0 {
        length += 1;
    }
    // SAFETY：前面的扫描已经确定有效 UTF-16 单元范围。
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(pointer, length) })
}

fn set_status(state: u32, exit_code: u32, service_exit_code: u32, wait_hint: u32) {
    let handle: SERVICE_STATUS_HANDLE = STATUS_HANDLE.load(Ordering::Relaxed);
    if handle.is_null() {
        return;
    }
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
        dwCheckPoint: 0,
        dwWaitHint: wait_hint,
    };
    // SAFETY：状态句柄由 RegisterServiceCtrlHandlerExW 返回，结构体在调用期间有效。
    unsafe { SetServiceStatus(handle, &status) };
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

mod auth;
mod client_error;
mod evidence;
mod identity;
mod scm;
mod sleep_resume;
mod unbuffered_file;
mod workload;

use std::time::{Duration, Instant};

use storpulse_windows_ipc::ProductPipe;
use storpulse_windows_service_contract::{
    ClientMessage, CollectionSession, PRODUCT_SERVICE_NAME, PROTOCOL_VERSION,
    SNAPSHOT_SCHEMA_VERSION, ServiceMessage,
};

use crate::{GateMode, GateOptions, GateReport, GateStatus};

use self::client_error::ClientError;
use self::evidence::{failure_outcome, finish_report, record_snapshot};

const CONNECTION_TIMEOUT: Duration = Duration::from_secs(15);
const MESSAGE_TIMEOUT: Duration = Duration::from_secs(3);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(45);
const WORKLOAD_COMPLETION_TIMEOUT: Duration = Duration::from_secs(10);

pub fn run_gate(options: &GateOptions) -> GateReport {
    let mut report = GateReport::new(options, PRODUCT_SERVICE_NAME);
    let mut service_started = false;
    let result = run_session(options, &mut report, &mut service_started);

    if service_started {
        match scm::wait_until_stopped(Instant::now() + SHUTDOWN_TIMEOUT) {
            Ok(status) => {
                report.service_stopped = status.stopped;
                report.service_win32_exit_code = Some(status.win32_exit_code);
                report.service_specific_exit_code = Some(status.service_specific_exit_code);
            }
            Err(error) if result.is_ok() => report.failure = Some(error.safe_failure()),
            Err(_) => {}
        }
    }

    match result {
        Ok(()) => finish_report(&mut report),
        Err(error) => {
            report.status = GateStatus::Failed;
            report.outcome = failure_outcome(options.mode);
            report.failure = Some(error.safe_failure());
        }
    }
    report
}

fn run_session(
    options: &GateOptions,
    report: &mut GateReport,
    service_started: &mut bool,
) -> Result<(), ClientError> {
    let elevated = identity::current_process_elevated()?;
    report.client_elevated = Some(elevated);
    if elevated {
        return Err(ClientError::new(
            "environment",
            "standard_user_required",
            Some(5),
        ));
    }

    let nonce = auth::generate_nonce()?;
    report.service_process_id = Some(scm::start(&nonce)?);
    *service_started = true;

    if options.mode == GateMode::ConnectTimeoutCleanup {
        return Ok(());
    }

    let pipe = ProductPipe::connect_client(Instant::now() + CONNECTION_TIMEOUT, None)?;
    let mut session = CollectionSession::default();
    session.begin_connecting()?;
    pipe.write_message_until(
        &ClientMessage::Connect {
            protocol_version: PROTOCOL_VERSION,
            snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
            run_id: options.run_id.clone(),
            nonce,
            client_process_id: report.client_process_id,
        },
        Instant::now() + MESSAGE_TIMEOUT,
        None,
    )?;

    let ready = receive(&pipe, &mut session, Instant::now() + MESSAGE_TIMEOUT)?;
    let ServiceMessage::Ready {
        service_process_id, ..
    } = ready
    else {
        return Err(ClientError::protocol("expected_ready"));
    };
    report.service_process_id = Some(service_process_id);

    if options.mode == GateMode::DisconnectCleanup {
        drop(pipe);
        return Ok(());
    }

    run_continuous(options, report, pipe, session)
}

fn run_continuous(
    options: &GateOptions,
    report: &mut GateReport,
    pipe: ProductPipe,
    mut session: CollectionSession,
) -> Result<(), ClientError> {
    pipe.write_message_until(
        &ClientMessage::StartCollection {
            protocol_version: PROTOCOL_VERSION,
        },
        Instant::now() + MESSAGE_TIMEOUT,
        None,
    )?;
    let started = receive(&pipe, &mut session, Instant::now() + MESSAGE_TIMEOUT)?;
    if !matches!(started, ServiceMessage::CollectionStarted { .. }) {
        return Err(ClientError::protocol("expected_collection_started"));
    }
    if options.mode == GateMode::ClientTerminationCleanup {
        terminate_process_for_gate();
    }
    if options.mode == GateMode::SleepResumeValidation {
        return sleep_resume::run(options, report, &pipe, &mut session);
    }

    report.workload.attempted = true;
    let receiver = workload::spawn(options.output_directory.clone());

    let collection_deadline = Instant::now() + Duration::from_secs(options.duration_seconds);
    while Instant::now() < collection_deadline {
        let read_deadline = std::cmp::min(
            collection_deadline + MESSAGE_TIMEOUT,
            Instant::now() + MESSAGE_TIMEOUT,
        );
        let message = receive(&pipe, &mut session, read_deadline)?;
        let ServiceMessage::Snapshot {
            sequence, snapshot, ..
        } = message
        else {
            return Err(ClientError::protocol("expected_snapshot"));
        };
        record_snapshot(
            &mut report.snapshots,
            sequence,
            &snapshot,
            report.client_process_id,
        );
    }

    complete_protocol(&pipe, &mut session, report)?;
    drop(pipe);

    report.workload = receiver
        .recv_timeout(WORKLOAD_COMPLETION_TIMEOUT)
        .map_err(|_| ClientError::new("workload", "workload_timeout", Some(1460)))??;
    Ok(())
}

fn complete_protocol(
    pipe: &ProductPipe,
    session: &mut CollectionSession,
    report: &mut GateReport,
) -> Result<(), ClientError> {
    session.request_stop()?;
    pipe.write_message_until(
        &ClientMessage::StopCollection {
            protocol_version: PROTOCOL_VERSION,
            last_sequence: session.last_sequence(),
        },
        Instant::now() + MESSAGE_TIMEOUT,
        None,
    )?;
    receive_until_stopped(pipe, session, report)?;
    pipe.write_message_until(
        &ClientMessage::AcknowledgeStop {
            protocol_version: PROTOCOL_VERSION,
        },
        Instant::now() + MESSAGE_TIMEOUT,
        None,
    )?;
    report.protocol_completed = true;
    Ok(())
}

fn terminate_process_for_gate() -> ! {
    // SAFETY：当前进程伪句柄始终有效；测试客户端用固定非零退出码模拟外部强杀。
    unsafe {
        windows_sys::Win32::System::Threading::TerminateProcess(
            windows_sys::Win32::System::Threading::GetCurrentProcess(),
            197,
        );
    }
    std::process::abort()
}

fn receive_until_stopped(
    pipe: &ProductPipe,
    session: &mut CollectionSession,
    report: &mut GateReport,
) -> Result<(), ClientError> {
    loop {
        let message = receive(pipe, session, Instant::now() + MESSAGE_TIMEOUT)?;
        match message {
            ServiceMessage::Snapshot {
                sequence, snapshot, ..
            } => record_snapshot(
                &mut report.snapshots,
                sequence,
                &snapshot,
                report.client_process_id,
            ),
            ServiceMessage::Stopped { final_sequence, .. } => {
                report.snapshots.final_sequence = final_sequence;
                return Ok(());
            }
            _ => return Err(ClientError::protocol("expected_draining_message")),
        }
    }
}

fn receive(
    pipe: &ProductPipe,
    session: &mut CollectionSession,
    deadline: Instant,
) -> Result<ServiceMessage, ClientError> {
    let message: ServiceMessage = pipe.read_message_until(deadline, None)?;
    if let ServiceMessage::Failed {
        phase,
        safe_error_code,
        native_code,
        ..
    } = &message
    {
        session.fail();
        return Err(ClientError::remote(*phase, *safe_error_code, *native_code));
    }
    session.observe(&message)?;
    Ok(message)
}

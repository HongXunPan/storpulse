mod auth;
mod client_error;
mod evidence;
mod ffi;
mod identity;
mod product_session;
mod scm;
mod sleep_resume;
mod unbuffered_file;
mod workload;

use std::time::{Duration, Instant};

use storpulse_windows_service_contract::PRODUCT_SERVICE_NAME;

use crate::{GateMode, GateOptions, GateReport, GateStatus};

use self::client_error::ClientError;
use self::evidence::{failure_outcome, finish_report, record_snapshot};
use self::product_session::ProductSession;

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

    let (session, service_process_id) =
        ProductSession::connect(options.run_id.clone(), nonce, report.client_process_id)?;
    report.service_process_id = Some(service_process_id);

    if options.mode == GateMode::DisconnectCleanup {
        drop(session);
        return Ok(());
    }

    run_continuous(options, report, session)
}

fn run_continuous(
    options: &GateOptions,
    report: &mut GateReport,
    mut session: ProductSession,
) -> Result<(), ClientError> {
    session.start_collection()?;
    if options.mode == GateMode::ClientTerminationCleanup {
        terminate_process_for_gate();
    }
    if options.mode == GateMode::SleepResumeValidation {
        return sleep_resume::run(options, report, &mut session);
    }

    report.workload.attempted = true;
    let receiver = workload::spawn(options.output_directory.clone());

    let collection_deadline = Instant::now() + Duration::from_secs(options.duration_seconds);
    while Instant::now() < collection_deadline {
        let read_deadline = std::cmp::min(
            collection_deadline + MESSAGE_TIMEOUT,
            Instant::now() + MESSAGE_TIMEOUT,
        );
        let (sequence, snapshot) = session.receive_snapshot(read_deadline)?;
        record_snapshot(
            &mut report.snapshots,
            sequence,
            &snapshot,
            report.client_process_id,
        );
    }

    complete_protocol(&mut session, report)?;
    drop(session);

    report.workload = receiver
        .recv_timeout(WORKLOAD_COMPLETION_TIMEOUT)
        .map_err(|_| ClientError::new("workload", "workload_timeout", Some(1460)))??;
    Ok(())
}

fn complete_protocol(
    session: &mut ProductSession,
    report: &mut GateReport,
) -> Result<(), ClientError> {
    let drained = session.stop_collection()?;
    for (sequence, snapshot) in drained.snapshots {
        record_snapshot(
            &mut report.snapshots,
            sequence,
            &snapshot,
            report.client_process_id,
        );
    }
    report.snapshots.final_sequence = drained.final_sequence;
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

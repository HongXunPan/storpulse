use std::time::{Duration, Instant};

use crate::model::{EtwEventReport, ServiceGateReport, Stage0Report, WorkloadReport};
use crate::options::ProbeOptions;
use crate::report::write_reports;

use super::super::{
    calculate_self_measurements, capture_process_scan, capture_self, push_timeline, record_error,
    unix_milliseconds, workload,
};
use super::protocol::{SCHEMA_VERSION, ServiceRequest, ServiceResponse};
use super::transport::Pipe;
use super::{ServiceFailure, auth, scm};

pub(super) fn run(options: ProbeOptions) -> Result<(), ServiceFailure> {
    std::fs::create_dir_all(&options.output_directory)
        .map_err(|_| ServiceFailure::new("report", "create_output_directory", 5))?;

    let started = Instant::now();
    let process_id = std::process::id();
    let mut timeline = Vec::new();
    let mut errors = Vec::new();
    push_timeline(
        &mut timeline,
        started,
        "info",
        "service_probe",
        "started",
        None,
    );

    let process_scan_before =
        capture_process_scan(&mut errors, &mut timeline, started, "process_scan_before");
    let self_before = capture_self(&mut errors, &mut timeline, started, "self_idle_start");
    std::thread::sleep(Duration::from_secs(2));
    let self_idle = capture_self(&mut errors, &mut timeline, started, "self_idle_end");

    let capture =
        match capture_from_service(&options, process_id, started, &mut timeline, &mut errors) {
            Ok(capture) => capture,
            Err(error) => {
                let cleanup = scm::wait_until_stopped(Instant::now() + Duration::from_secs(45));
                let cleanup_confirmed = matches!(cleanup, Ok(true));
                push_timeline(
                    &mut timeline,
                    started,
                    if cleanup_confirmed { "info" } else { "error" },
                    "service_control",
                    if cleanup_confirmed {
                        "stopped_after_failure"
                    } else {
                        "cleanup_unconfirmed"
                    },
                    None,
                );
                push_timeline(
                    &mut timeline,
                    started,
                    "error",
                    error.phase,
                    error.api,
                    Some(error.code),
                );
                errors.push(error.diagnostic());
                ServiceCapture::default()
            }
        };

    let self_after = capture_self(&mut errors, &mut timeline, started, "self_workload_end");
    let process_scan_after =
        capture_process_scan(&mut errors, &mut timeline, started, "process_scan_after");
    let self_measurements = calculate_self_measurements(&self_before, &self_idle, &self_after);
    let outcome = if options.disconnect_after_ready {
        if capture
            .service
            .as_ref()
            .is_some_and(|service| service.service_stopped)
        {
            "windows_service_disconnect_cleanup_collected"
        } else {
            "windows_service_disconnect_cleanup_failed"
        }
    } else if capture.etw.session_started
        && capture.etw.consumer_started
        && capture.workload.completed
        && capture
            .service
            .as_ref()
            .is_some_and(|service| service.service_stopped)
    {
        "windows_service_diagnostic_collected"
    } else {
        "windows_service_diagnostic_restricted"
    };

    let report = Stage0Report {
        schema_version: 1,
        generated_at_unix_milliseconds: unix_milliseconds(),
        evidence_level: "Windows 10 按需服务候选门禁，非 Windows 11 正式门禁",
        metric_source: "windows.localsystem-service.etw-system-diskio+standard-client",
        outcome,
        environment: super::super::environment::collect(process_id),
        process_scan_before,
        process_scan_after,
        self_measurements,
        etw: capture.etw,
        workload: capture.workload,
        service: capture.service,
        errors,
        limitations: vec![
            "按需服务是独立增强权限候选，不改变标准用户 ETW 门禁失败结论",
            "Windows 10 结果不能替代 Windows 11、Windows on ARM、签名或正式安装门禁",
            "LocalSystem 服务不接收路径、命令行、ETW Provider 或任意文件写入参数",
            "服务只通过本地命名管道返回内存聚合结果，诊断文件由标准用户客户端写入",
            "异常断开测试只证明管道断开后的服务停止，不替代强杀、休眠和长期运行验证",
            "设备总量与进程量尚未证明可比较，不计算未归因差额",
        ],
    };
    write_reports(&options.output_directory, &report, &timeline)
        .map_err(|_| ServiceFailure::new("report", "write_reports", 5))?;
    println!("Windows 按需服务门禁诊断完成，请返回生成的 diagnostics ZIP。");
    Ok(())
}

fn capture_from_service(
    options: &ProbeOptions,
    process_id: u32,
    started: Instant,
    timeline: &mut Vec<crate::model::TimelineEvent>,
    errors: &mut Vec<crate::model::DiagnosticError>,
) -> Result<ServiceCapture, ServiceFailure> {
    let nonce = auth::generate_nonce()?;
    scm::start(&nonce)?;
    push_timeline(
        timeline,
        started,
        "info",
        "service_control",
        "running",
        None,
    );

    let pipe = Pipe::connect_client(Instant::now() + Duration::from_secs(15))?;
    pipe.write_message(&ServiceRequest::Begin {
        schema_version: SCHEMA_VERSION,
        nonce,
        client_process_id: process_id,
        duration_seconds: options.duration_seconds,
    })?;
    let ready: ServiceResponse =
        pipe.read_message_until(Instant::now() + Duration::from_secs(10), None)?;
    if ready.schema_version() != SCHEMA_VERSION {
        return Err(ServiceFailure::new(
            "protocol",
            "unsupported_ready_schema",
            87,
        ));
    }
    let ready = match ready {
        ServiceResponse::Ready {
            service_process_id,
            service_local_system,
            client_process_id_matched,
            client_elevated,
            ..
        } => Ready {
            service_process_id,
            service_local_system,
            client_process_id_matched,
            client_elevated,
        },
        ServiceResponse::Failed { code, .. } => {
            return Err(ServiceFailure::new(
                "service_runtime",
                "remote_service_failure",
                code,
            ));
        }
        ServiceResponse::Completed { .. } => {
            return Err(ServiceFailure::new(
                "protocol",
                "completed_before_ready",
                13,
            ));
        }
    };
    push_timeline(
        timeline,
        started,
        "info",
        "service_ipc",
        "collector_ready",
        None,
    );

    if options.disconnect_after_ready {
        drop(pipe);
        let stopped = scm::wait_until_stopped(Instant::now() + Duration::from_secs(30))?;
        return Ok(ServiceCapture {
            service: Some(ServiceGateReport {
                service_name: super::SERVICE_NAME.to_string(),
                service_process_id: ready.service_process_id,
                service_local_system: ready.service_local_system,
                client_process_id_matched: ready.client_process_id_matched,
                client_elevated: ready.client_elevated,
                client_authenticated: true,
                pipe_reject_remote_clients: true,
                service_stopped: stopped,
                disconnect_cleanup_test: true,
                service_self_measurements: Default::default(),
            }),
            ..Default::default()
        });
    }

    let trace_window_started = Instant::now();
    let outcome = workload::perform(&options.output_directory, options.skip_workload);
    let (workload, identities, handles) = match outcome {
        Ok(outcome) => (
            outcome.report,
            outcome.short_lived_processes,
            outcome.short_lived_process_handles,
        ),
        Err(error) => {
            record_error(errors, timeline, started, error);
            (WorkloadReport::default(), Vec::new(), Vec::new())
        }
    };
    let requested_duration = Duration::from_secs(options.duration_seconds);
    if let Some(remaining) = requested_duration.checked_sub(trace_window_started.elapsed()) {
        std::thread::sleep(remaining);
    }
    pipe.write_message(&ServiceRequest::Finish {
        schema_version: SCHEMA_VERSION,
        short_lived_processes: identities,
    })?;
    let completed: ServiceResponse =
        pipe.read_message_until(Instant::now() + Duration::from_secs(15), None)?;
    let (etw, mut service) = match completed {
        ServiceResponse::Completed { etw, service, .. } => (*etw, service),
        ServiceResponse::Failed { code, .. } => {
            return Err(ServiceFailure::new(
                "service_runtime",
                "remote_service_failure",
                code,
            ));
        }
        ServiceResponse::Ready { .. } => {
            return Err(ServiceFailure::new(
                "protocol",
                "duplicate_ready_response",
                13,
            ));
        }
    };
    drop(pipe);
    service.service_stopped = scm::wait_until_stopped(Instant::now() + Duration::from_secs(30))?;
    drop(handles);

    Ok(ServiceCapture {
        etw,
        workload,
        service: Some(service),
    })
}

#[derive(Default)]
struct ServiceCapture {
    etw: EtwEventReport,
    workload: WorkloadReport,
    service: Option<ServiceGateReport>,
}

struct Ready {
    service_process_id: u32,
    service_local_system: bool,
    client_process_id_matched: bool,
    client_elevated: Option<bool>,
}

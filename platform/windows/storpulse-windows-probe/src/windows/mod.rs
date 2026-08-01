mod environment;
mod error;
mod etw;
mod process;
mod service;
mod unbuffered_file;
mod workload;

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::model::{
    DiagnosticError, EtwEventReport, ProcessMeasurements, ProcessScanReport, SelfMeasurementReport,
    Stage0Report, TimelineEvent, WorkloadReport, delta,
};
use crate::options::{ProbeCommand, ProbeOptions};
use crate::report::write_reports;

use self::error::{NativeFailure, RunError};

pub fn run() -> Result<(), RunError> {
    match ProbeCommand::parse().map_err(RunError::new)? {
        ProbeCommand::Diagnostic(options) => {
            if options.service_mode {
                service::run_diagnostic(options)
            } else {
                run_diagnostic(options)
            }
        }
        ProbeCommand::Service => service::run_dispatcher(),
        ProbeCommand::ShortLivedRead(path) => {
            workload::perform_short_lived_read(&path).map_err(|error| {
                RunError::new(format!("短命读取负载失败：{} ({})", error.api, error.code))
            })
        }
    }
}

fn run_diagnostic(options: ProbeOptions) -> Result<(), RunError> {
    std::fs::create_dir_all(&options.output_directory)
        .map_err(|_| RunError::new("无法创建诊断输出目录"))?;

    let started = Instant::now();
    let process_id = std::process::id();
    let mut timeline = Vec::new();
    let mut errors = Vec::new();
    push_timeline(&mut timeline, started, "info", "probe", "started", None);

    let process_scan_before =
        capture_process_scan(&mut errors, &mut timeline, started, "process_scan_before");
    let self_before = capture_self(&mut errors, &mut timeline, started, "self_idle_start");
    std::thread::sleep(Duration::from_secs(2));
    let self_idle = capture_self(&mut errors, &mut timeline, started, "self_idle_end");

    let trace_window_started = Instant::now();
    let (trace_session, mut etw_report) = match etw::TraceSession::start(process_id) {
        Ok(session) => {
            push_timeline(
                &mut timeline,
                started,
                "info",
                "etw",
                "consumer_ready",
                None,
            );
            (Some(session), EtwEventReport::default())
        }
        Err(error) => {
            let mut report = EtwEventReport {
                session_started: error.session_started,
                start_status: if error.session_started { 0 } else { error.code },
                open_status: if error.session_started { error.code } else { 0 },
                ..Default::default()
            };
            if !error.session_started {
                report.consumer_started = false;
            }
            record_error(&mut errors, &mut timeline, started, error);
            (None, report)
        }
    };

    let (workload, short_lived_processes, short_lived_process_handles) =
        match workload::perform(&options.output_directory, options.skip_workload) {
            Ok(outcome) => {
                push_timeline(
                    &mut timeline,
                    started,
                    "info",
                    "workload",
                    if options.skip_workload {
                        "skipped"
                    } else {
                        "completed"
                    },
                    None,
                );
                (
                    outcome.report,
                    outcome.short_lived_processes,
                    outcome.short_lived_process_handles,
                )
            }
            Err(error) => {
                record_error(&mut errors, &mut timeline, started, error);
                (
                    WorkloadReport {
                        attempted: !options.skip_workload,
                        ..Default::default()
                    },
                    Vec::new(),
                    Vec::new(),
                )
            }
        };

    let requested_duration = Duration::from_secs(options.duration_seconds);
    if let Some(remaining) = requested_duration.checked_sub(trace_window_started.elapsed()) {
        std::thread::sleep(remaining);
    }
    if let Some(session) = trace_session {
        etw_report = session.stop(process_id, &short_lived_processes);
        push_timeline(&mut timeline, started, "info", "etw", "stopped", None);
    }
    drop(short_lived_process_handles);

    let self_after = capture_self(&mut errors, &mut timeline, started, "self_workload_end");
    let process_scan_after =
        capture_process_scan(&mut errors, &mut timeline, started, "process_scan_after");
    let self_measurements = calculate_self_measurements(&self_before, &self_idle, &self_after);
    let outcome = if etw_report.session_started && etw_report.consumer_started && workload.completed
    {
        "windows_diagnostic_collected"
    } else {
        "windows_diagnostic_restricted"
    };

    push_timeline(
        &mut timeline,
        started,
        "info",
        "report",
        "ready_to_write",
        None,
    );
    let report = Stage0Report {
        schema_version: 1,
        generated_at_unix_milliseconds: unix_milliseconds(),
        evidence_level: "Windows 10/Server 协作诊断，非 Windows 11 正式门禁",
        metric_source: "windows.etw-system-diskio+getprocessiocounters-broad",
        outcome,
        environment: environment::collect(process_id),
        process_scan_before,
        process_scan_after,
        self_measurements,
        etw: etw_report,
        workload,
        service: None,
        errors,
        limitations: vec![
            "GetProcessIoCounters 是广义进程 I/O，不命名为磁盘专属 I/O",
            "Windows 10 或 Windows Server 结果不能替代 Windows 11 标准用户门禁",
            "诊断包不采集用户名、完整路径、命令行、文件内容或原始 ETL",
            "不缓存读取只绕过 Windows 系统文件缓存，不声称绕过设备硬件缓存",
            "ETW 线程到进程映射可能遗漏短命线程，必须结合 unmappedDiskEvents 判断",
            "短命进程只在单次诊断窗口内以 PID 与启动时间识别，并保留进程句柄到 ETW 停止；检测到 PID 重用时不判为通过",
            "设备总量与进程量尚未证明可比较，不计算未归因差额",
        ],
    };
    write_reports(&options.output_directory, &report, &timeline).map_err(RunError::new)?;
    println!("Windows 阶段 0 诊断完成，请返回生成的 diagnostics ZIP。");
    Ok(())
}

fn capture_process_scan(
    errors: &mut Vec<DiagnosticError>,
    timeline: &mut Vec<TimelineEvent>,
    started: Instant,
    event: &'static str,
) -> ProcessScanReport {
    match process::scan_processes() {
        Ok(report) => {
            push_timeline(timeline, started, "info", "process_scan", event, None);
            report
        }
        Err(error) => {
            record_error(errors, timeline, started, error);
            ProcessScanReport::default()
        }
    }
}

fn capture_self(
    errors: &mut Vec<DiagnosticError>,
    timeline: &mut Vec<TimelineEvent>,
    started: Instant,
    event: &'static str,
) -> ProcessMeasurements {
    match process::current_process() {
        Ok(measurement) => {
            push_timeline(timeline, started, "info", "self_measurement", event, None);
            measurement
        }
        Err(error) => {
            record_error(errors, timeline, started, error);
            ProcessMeasurements::default()
        }
    }
}

fn calculate_self_measurements(
    before: &ProcessMeasurements,
    idle: &ProcessMeasurements,
    after: &ProcessMeasurements,
) -> SelfMeasurementReport {
    SelfMeasurementReport {
        idle_read_delta_bytes: delta(before.io.read_bytes, idle.io.read_bytes),
        idle_write_delta_bytes: delta(before.io.write_bytes, idle.io.write_bytes),
        workload_read_delta_bytes: delta(idle.io.read_bytes, after.io.read_bytes),
        workload_write_delta_bytes: delta(idle.io.write_bytes, after.io.write_bytes),
        cpu_time_delta_ticks: delta(
            before
                .kernel_time_ticks
                .saturating_add(before.user_time_ticks),
            after
                .kernel_time_ticks
                .saturating_add(after.user_time_ticks),
        ),
        working_set_bytes: after.working_set_bytes,
        private_bytes: after.private_bytes,
    }
}

fn record_error(
    errors: &mut Vec<DiagnosticError>,
    timeline: &mut Vec<TimelineEvent>,
    started: Instant,
    error: NativeFailure,
) {
    push_timeline(
        timeline,
        started,
        "error",
        error.phase,
        error.api,
        Some(error.code),
    );
    errors.push(error.diagnostic());
}

fn push_timeline(
    timeline: &mut Vec<TimelineEvent>,
    started: Instant,
    level: &'static str,
    phase: &'static str,
    event: &'static str,
    code: Option<u32>,
) {
    timeline.push(TimelineEvent {
        elapsed_milliseconds: started.elapsed().as_millis(),
        level,
        phase,
        event,
        code,
    });
}

fn unix_milliseconds() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

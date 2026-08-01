use std::path::PathBuf;

use crate::{GateOptions, GateStatus};

use super::*;

#[test]
fn partial_process_coverage_can_pass_without_trace_loss() {
    let options = GateOptions {
        output_directory: PathBuf::from("reports"),
        run_id: "run-1".to_owned(),
        duration_seconds: 8,
        mode: GateMode::ContinuousValidation,
    };
    let mut report = GateReport::new(&options, "StorPulseCollector");
    report.protocol_completed = true;
    report.service_stopped = true;
    report.workload.attempted = true;
    report.workload.completed = true;
    report.workload.cleanup_succeeded = true;
    report.snapshots.snapshot_count = 4;
    report.snapshots.partial_snapshots = 4;
    report.snapshots.max_restricted_processes = 3;
    report.snapshots.client_process_observed = true;
    report.snapshots.client_read_bytes = 32 * 1_048_576;
    report.snapshots.device_read_bytes = 32 * 1_048_576;

    finish_report(&mut report);

    assert_eq!(report.status, GateStatus::Completed);
    assert_eq!(report.outcome, "windows_continuous_gate_completed");
}

#[test]
fn trace_loss_keeps_continuous_gate_restricted() {
    let options = GateOptions {
        output_directory: PathBuf::from("reports"),
        run_id: "run-2".to_owned(),
        duration_seconds: 8,
        mode: GateMode::ContinuousValidation,
    };
    let mut report = GateReport::new(&options, "StorPulseCollector");
    report.protocol_completed = true;
    report.service_stopped = true;
    report.workload.completed = true;
    report.workload.cleanup_succeeded = true;
    report.snapshots.snapshot_count = 4;
    report.snapshots.client_process_observed = true;
    report.snapshots.client_read_bytes = 1;
    report.snapshots.device_read_bytes = 1;
    report.snapshots.events_lost = 1;

    finish_report(&mut report);

    assert_eq!(report.status, GateStatus::Restricted);
}

#[test]
fn connection_timeout_requires_service_specific_timeout_exit() {
    let options = GateOptions {
        output_directory: PathBuf::from("reports"),
        run_id: "run-timeout".to_owned(),
        duration_seconds: 8,
        mode: GateMode::ConnectTimeoutCleanup,
    };
    let mut report = GateReport::new(&options, "StorPulseCollector");
    report.service_stopped = true;
    report.service_win32_exit_code = Some(1066);
    report.service_specific_exit_code = Some(1460);

    finish_report(&mut report);

    assert_eq!(report.status, GateStatus::Completed);
    assert!(report.connect_timeout_confirmed);
    assert_eq!(
        report.outcome,
        "windows_service_connect_timeout_cleanup_completed"
    );
}

#[test]
fn sleep_resume_requires_pre_and_post_resume_evidence() {
    let options = GateOptions {
        output_directory: PathBuf::from("reports"),
        run_id: "run-sleep-resume".to_owned(),
        duration_seconds: 8,
        mode: GateMode::SleepResumeValidation,
    };
    let mut report = GateReport::new(&options, "StorPulseCollector");
    report.protocol_completed = true;
    report.service_stopped = true;
    report.workload.attempted = true;
    report.workload.completed = true;
    report.workload.cleanup_succeeded = true;
    let evidence = report.sleep_resume.as_mut().unwrap();
    evidence.ready_for_sleep = true;
    evidence.suspend_detected = true;
    evidence.resume_detected = true;
    evidence.estimated_sleep_milliseconds = 8_000;
    evidence.sequence_continuity_confirmed = true;
    evidence.pre_sleep_snapshots = complete_snapshot_phase(3, 32, 32);
    evidence.post_resume_snapshots = complete_snapshot_phase(3, 64, 64);
    evidence.post_resume_workload.attempted = true;
    evidence.post_resume_workload.completed = true;
    evidence.post_resume_workload.cleanup_succeeded = true;

    finish_report(&mut report);

    assert_eq!(report.status, GateStatus::Completed);
    assert!(report.sleep_resume_confirmed);
    assert_eq!(report.outcome, "windows_sleep_resume_validation_completed");
}

fn complete_snapshot_phase(
    snapshot_count: u64,
    client_read_bytes: u64,
    device_read_bytes: u64,
) -> SnapshotEvidence {
    SnapshotEvidence {
        snapshot_count,
        client_process_observed: true,
        client_read_bytes,
        device_read_bytes,
        ..SnapshotEvidence::default()
    }
}

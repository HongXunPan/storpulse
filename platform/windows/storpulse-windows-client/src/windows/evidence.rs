use storpulse_core::model::{Completeness, RawSnapshot};

use crate::{GateMode, GateReport, GateStatus, SafeFailure, SnapshotEvidence};

pub(super) fn record_snapshot(
    evidence: &mut SnapshotEvidence,
    sequence: u64,
    snapshot: &RawSnapshot,
    client_process_id: u32,
) {
    evidence.snapshot_count = evidence.snapshot_count.saturating_add(1);
    evidence.first_sequence.get_or_insert(sequence);
    evidence.last_sequence = Some(sequence);
    match snapshot.completeness {
        Completeness::Complete => {
            evidence.complete_snapshots = evidence.complete_snapshots.saturating_add(1)
        }
        Completeness::Partial => {
            evidence.partial_snapshots = evidence.partial_snapshots.saturating_add(1)
        }
        Completeness::Restricted | Completeness::Unsupported => {
            evidence.restricted_snapshots = evidence.restricted_snapshots.saturating_add(1)
        }
    }
    evidence.max_processes = evidence.max_processes.max(snapshot.processes.len());
    evidence.max_restricted_processes = evidence
        .max_restricted_processes
        .max(snapshot.summary.restricted_processes);
    evidence.max_devices = evidence.max_devices.max(snapshot.devices.len());
    if let Some(process) = snapshot
        .processes
        .iter()
        .find(|process| process.identity.pid == client_process_id as i32)
    {
        evidence.client_process_observed = true;
        evidence.client_read_bytes = evidence.client_read_bytes.max(process.read_bytes);
        evidence.client_write_bytes = evidence.client_write_bytes.max(process.write_bytes);
    }
    let device_read_bytes = snapshot.devices.iter().fold(0_u64, |total, device| {
        total.saturating_add(device.read_bytes)
    });
    let device_write_bytes = snapshot.devices.iter().fold(0_u64, |total, device| {
        total.saturating_add(device.write_bytes)
    });
    evidence.device_read_bytes = evidence.device_read_bytes.max(device_read_bytes);
    evidence.device_write_bytes = evidence.device_write_bytes.max(device_write_bytes);
    evidence.unmapped_disk_events = evidence
        .unmapped_disk_events
        .max(snapshot.summary.unmapped_disk_events);
    evidence.events_lost = evidence.events_lost.max(snapshot.summary.events_lost);
    evidence.buffers_lost = evidence.buffers_lost.max(snapshot.summary.buffers_lost);
}

pub(super) fn finish_report(report: &mut GateReport) {
    match report.mode {
        GateMode::DisconnectCleanup => return finish_disconnect_report(report),
        GateMode::ConnectTimeoutCleanup => return finish_connect_timeout_report(report),
        GateMode::ClientTerminationCleanup => {
            return fail_for_service_stop(
                report,
                "windows_client_termination_cleanup_not_triggered",
            );
        }
        GateMode::SleepResumeValidation => return finish_sleep_resume_report(report),
        GateMode::ContinuousValidation => {}
    }
    if !report.service_stopped {
        fail_for_service_stop(report, "windows_continuous_gate_failed");
        return;
    }

    let evidence_complete = report.protocol_completed
        && report.workload.completed
        && report.workload.cleanup_succeeded
        && report.snapshots.snapshot_count >= 3
        && report.snapshots.client_process_observed
        && report.snapshots.client_read_bytes > 0
        && report.snapshots.device_read_bytes > 0
        && report.snapshots.unmapped_disk_events == 0
        && report.snapshots.events_lost == 0
        && report.snapshots.buffers_lost == 0;
    if evidence_complete {
        report.status = GateStatus::Completed;
        report.outcome = "windows_continuous_gate_completed";
    } else {
        report.status = GateStatus::Restricted;
        report.outcome = "windows_continuous_gate_restricted";
    }
}

pub(super) fn failure_outcome(mode: GateMode) -> &'static str {
    match mode {
        GateMode::ContinuousValidation => "windows_continuous_gate_failed",
        GateMode::DisconnectCleanup => "windows_service_disconnect_cleanup_failed",
        GateMode::ConnectTimeoutCleanup => "windows_service_connect_timeout_cleanup_failed",
        GateMode::ClientTerminationCleanup => "windows_client_termination_cleanup_failed",
        GateMode::SleepResumeValidation => "windows_sleep_resume_validation_failed",
    }
}

fn finish_sleep_resume_report(report: &mut GateReport) {
    if !report.service_stopped {
        fail_for_service_stop(report, "windows_sleep_resume_validation_failed");
        return;
    }
    let Some(evidence) = report.sleep_resume.as_ref() else {
        report.status = GateStatus::Failed;
        report.outcome = "windows_sleep_resume_validation_failed";
        report.failure = Some(SafeFailure::new(
            "sleep_resume",
            "sleep_resume_evidence_missing",
            None,
        ));
        return;
    };

    report.sleep_resume_confirmed = report.protocol_completed
        && evidence.ready_for_sleep
        && evidence.suspend_detected
        && evidence.resume_detected
        && evidence.estimated_sleep_milliseconds >= super::sleep_resume::MINIMUM_SLEEP_MILLISECONDS
        && evidence.sequence_continuity_confirmed
        && snapshot_phase_complete(&evidence.pre_sleep_snapshots)
        && snapshot_phase_complete(&evidence.post_resume_snapshots)
        && workload_complete(&report.workload)
        && workload_complete(&evidence.post_resume_workload)
        && evidence.post_resume_snapshots.client_read_bytes
            > evidence.pre_sleep_snapshots.client_read_bytes
        && evidence.post_resume_snapshots.device_read_bytes
            > evidence.pre_sleep_snapshots.device_read_bytes
        && report.snapshots.unmapped_disk_events == 0
        && report.snapshots.events_lost == 0
        && report.snapshots.buffers_lost == 0;
    if report.sleep_resume_confirmed {
        report.status = GateStatus::Completed;
        report.outcome = "windows_sleep_resume_validation_completed";
    } else {
        report.status = GateStatus::Restricted;
        report.outcome = "windows_sleep_resume_validation_restricted";
    }
}

pub(super) fn snapshot_phase_complete(evidence: &SnapshotEvidence) -> bool {
    evidence.snapshot_count >= 3
        && evidence.client_process_observed
        && evidence.client_read_bytes > 0
        && evidence.device_read_bytes > 0
        && evidence.unmapped_disk_events == 0
        && evidence.events_lost == 0
        && evidence.buffers_lost == 0
}

pub(super) fn workload_complete(evidence: &crate::WorkloadEvidence) -> bool {
    evidence.attempted && evidence.completed && evidence.cleanup_succeeded
}

fn finish_disconnect_report(report: &mut GateReport) {
    report.disconnect_cleanup_confirmed = report.service_stopped;
    if report.service_stopped {
        report.status = GateStatus::Completed;
        report.outcome = "windows_service_disconnect_cleanup_completed";
    } else {
        fail_for_service_stop(report, "windows_service_disconnect_cleanup_failed");
    }
}

fn finish_connect_timeout_report(report: &mut GateReport) {
    report.connect_timeout_confirmed = report.service_stopped
        && report.service_win32_exit_code == Some(1066)
        && report.service_specific_exit_code == Some(1460)
        && report.snapshots.snapshot_count == 0
        && !report.workload.attempted;
    if report.connect_timeout_confirmed {
        report.status = GateStatus::Completed;
        report.outcome = "windows_service_connect_timeout_cleanup_completed";
    } else if !report.service_stopped {
        fail_for_service_stop(report, "windows_service_connect_timeout_cleanup_failed");
    } else {
        report.status = GateStatus::Failed;
        report.outcome = "windows_service_connect_timeout_cleanup_failed";
        report.failure = Some(SafeFailure::new(
            "connection",
            "connect_timeout_evidence_mismatch",
            report
                .service_specific_exit_code
                .or(report.service_win32_exit_code),
        ));
    }
}

fn fail_for_service_stop(report: &mut GateReport, outcome: &'static str) {
    report.status = GateStatus::Failed;
    report.outcome = outcome;
    report.failure = Some(SafeFailure::new(
        "shutdown",
        "service_stop_timeout",
        Some(1460),
    ));
}

#[cfg(test)]
mod tests;

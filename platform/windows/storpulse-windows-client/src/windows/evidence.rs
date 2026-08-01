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
    if report.mode == GateMode::DisconnectCleanup {
        finish_disconnect_report(report);
        return;
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

pub(super) fn failure_outcome(disconnect_after_ready: bool) -> &'static str {
    if disconnect_after_ready {
        "windows_service_disconnect_cleanup_failed"
    } else {
        "windows_continuous_gate_failed"
    }
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
mod tests {
    use std::path::PathBuf;

    use crate::{GateOptions, GateStatus};

    use super::*;

    #[test]
    fn partial_process_coverage_can_pass_without_trace_loss() {
        let options = GateOptions {
            output_directory: PathBuf::from("reports"),
            run_id: "run-1".to_owned(),
            duration_seconds: 8,
            disconnect_after_ready: false,
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
            disconnect_after_ready: false,
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
}

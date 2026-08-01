use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, TryRecvError};
use std::time::{Duration, Instant};

use storpulse_windows_ipc::ProductPipe;
use storpulse_windows_service_contract::{CollectionSession, ServiceMessage};

use crate::{GateOptions, GateReport, WorkloadEvidence};

mod clock;

use clock::SuspendDetector;

use super::evidence::{record_snapshot, snapshot_phase_complete, workload_complete};
use super::{ClientError, complete_protocol, receive, workload};

const READY_MARKER_NAME: &str = ".sleep-resume-ready";
pub(super) const MINIMUM_SLEEP_MILLISECONDS: u64 = 2_000;
const SLEEP_WAIT_TIMEOUT: Duration = Duration::from_secs(300);
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(3);

pub(super) fn run(
    options: &GateOptions,
    report: &mut GateReport,
    pipe: &ProductPipe,
    session: &mut CollectionSession,
) -> Result<(), ClientError> {
    if report.sleep_resume.is_none() {
        return Err(ClientError::new(
            "sleep_resume",
            "sleep_resume_evidence_missing",
            None,
        ));
    }

    collect_pre_sleep_evidence(options, report, pipe, session)?;
    let mut detector = SuspendDetector::new()?;
    let ready_tick_count = detector.baseline_tick_count_milliseconds();
    let marker = ReadyMarker::create(&options.output_directory)?;
    if let Some(evidence) = report.sleep_resume.as_mut() {
        evidence.ready_for_sleep = true;
    }

    wait_for_resume(report, pipe, session, &mut detector, ready_tick_count)?;
    drop(marker);
    collect_post_resume_evidence(options, report, pipe, session)?;
    complete_protocol(pipe, session, report)
}

fn collect_pre_sleep_evidence(
    options: &GateOptions,
    report: &mut GateReport,
    pipe: &ProductPipe,
    session: &mut CollectionSession,
) -> Result<(), ClientError> {
    report.workload.attempted = true;
    let receiver = workload::spawn(options.output_directory.clone());
    let deadline = Instant::now() + Duration::from_secs(options.duration_seconds);
    let mut workload_result = None;

    while Instant::now() < deadline {
        let (sequence, snapshot) = receive_snapshot(pipe, session, SNAPSHOT_TIMEOUT)?;
        record_phase_snapshot(report, sequence, &snapshot, false)?;
        poll_workload(&receiver, &mut workload_result)?;
        if pre_sleep_ready(report, workload_result.as_ref()) {
            break;
        }
    }

    let workload = workload_result.ok_or_else(|| {
        ClientError::new("sleep_resume", "pre_sleep_workload_timeout", Some(1460))
    })?;
    let evidence_complete = pre_sleep_ready(report, Some(&workload));
    report.workload = workload;
    if !evidence_complete {
        return Err(ClientError::new(
            "sleep_resume",
            "pre_sleep_evidence_incomplete",
            None,
        ));
    }
    Ok(())
}

fn wait_for_resume(
    report: &mut GateReport,
    pipe: &ProductPipe,
    session: &mut CollectionSession,
    detector: &mut SuspendDetector,
    ready_tick_count: u64,
) -> Result<(), ClientError> {
    loop {
        let (sequence, snapshot) = receive_snapshot(pipe, session, SLEEP_WAIT_TIMEOUT)?;
        let observation = detector.observe()?;
        if observation.estimated_sleep_milliseconds >= MINIMUM_SLEEP_MILLISECONDS {
            if let Some(evidence) = report.sleep_resume.as_mut() {
                evidence.suspend_detected = true;
                evidence.resume_detected = true;
                evidence.estimated_sleep_milliseconds = observation.estimated_sleep_milliseconds;
                evidence.sequence_continuity_confirmed = evidence
                    .pre_sleep_snapshots
                    .last_sequence
                    .and_then(|value| value.checked_add(1))
                    == Some(sequence);
            }
            record_phase_snapshot(report, sequence, &snapshot, true)?;
            return Ok(());
        }

        record_phase_snapshot(report, sequence, &snapshot, false)?;
        if observation
            .tick_count_milliseconds
            .saturating_sub(ready_tick_count)
            >= SLEEP_WAIT_TIMEOUT.as_millis() as u64
        {
            return Err(ClientError::new(
                "sleep_resume",
                "sleep_not_detected",
                Some(1460),
            ));
        }
    }
}

fn collect_post_resume_evidence(
    options: &GateOptions,
    report: &mut GateReport,
    pipe: &ProductPipe,
    session: &mut CollectionSession,
) -> Result<(), ClientError> {
    let receiver = workload::spawn(options.output_directory.clone());
    if let Some(evidence) = report.sleep_resume.as_mut() {
        evidence.post_resume_workload.attempted = true;
    }
    let deadline = Instant::now() + Duration::from_secs(options.duration_seconds);
    let mut workload_result = None;

    while Instant::now() < deadline {
        let (sequence, snapshot) = receive_snapshot(pipe, session, SNAPSHOT_TIMEOUT)?;
        record_phase_snapshot(report, sequence, &snapshot, true)?;
        poll_workload(&receiver, &mut workload_result)?;
        if post_resume_ready(report, workload_result.as_ref()) {
            break;
        }
    }

    let workload = workload_result.ok_or_else(|| {
        ClientError::new("sleep_resume", "post_resume_workload_timeout", Some(1460))
    })?;
    let evidence_complete = post_resume_ready(report, Some(&workload));
    if let Some(evidence) = report.sleep_resume.as_mut() {
        evidence.post_resume_workload = workload;
    }
    if !evidence_complete {
        return Err(ClientError::new(
            "sleep_resume",
            "post_resume_evidence_incomplete",
            None,
        ));
    }
    Ok(())
}

fn receive_snapshot(
    pipe: &ProductPipe,
    session: &mut CollectionSession,
    timeout: Duration,
) -> Result<(u64, storpulse_core::model::RawSnapshot), ClientError> {
    let message = receive(pipe, session, Instant::now() + timeout)?;
    let ServiceMessage::Snapshot {
        sequence, snapshot, ..
    } = message
    else {
        return Err(ClientError::protocol("expected_snapshot"));
    };
    Ok((sequence, *snapshot))
}

fn record_phase_snapshot(
    report: &mut GateReport,
    sequence: u64,
    snapshot: &storpulse_core::model::RawSnapshot,
    post_resume: bool,
) -> Result<(), ClientError> {
    record_snapshot(
        &mut report.snapshots,
        sequence,
        snapshot,
        report.client_process_id,
    );
    let evidence = report
        .sleep_resume
        .as_mut()
        .ok_or_else(|| ClientError::new("sleep_resume", "sleep_resume_evidence_missing", None))?;
    let phase = if post_resume {
        &mut evidence.post_resume_snapshots
    } else {
        &mut evidence.pre_sleep_snapshots
    };
    record_snapshot(phase, sequence, snapshot, report.client_process_id);
    Ok(())
}

fn pre_sleep_ready(report: &GateReport, workload: Option<&WorkloadEvidence>) -> bool {
    let Some(evidence) = report.sleep_resume.as_ref() else {
        return false;
    };
    workload.is_some_and(workload_complete)
        && snapshot_phase_complete(&evidence.pre_sleep_snapshots)
}

fn post_resume_ready(report: &GateReport, workload: Option<&WorkloadEvidence>) -> bool {
    let Some(evidence) = report.sleep_resume.as_ref() else {
        return false;
    };
    workload.is_some_and(workload_complete)
        && snapshot_phase_complete(&evidence.post_resume_snapshots)
        && evidence.post_resume_snapshots.client_read_bytes
            > evidence.pre_sleep_snapshots.client_read_bytes
        && evidence.post_resume_snapshots.device_read_bytes
            > evidence.pre_sleep_snapshots.device_read_bytes
}

fn poll_workload(
    receiver: &Receiver<Result<WorkloadEvidence, ClientError>>,
    result: &mut Option<WorkloadEvidence>,
) -> Result<(), ClientError> {
    if result.is_some() {
        return Ok(());
    }
    match receiver.try_recv() {
        Ok(workload) => *result = Some(workload?),
        Err(TryRecvError::Empty) => {}
        Err(TryRecvError::Disconnected) => {
            return Err(ClientError::new(
                "workload",
                "workload_worker_disconnected",
                None,
            ));
        }
    }
    Ok(())
}

struct ReadyMarker {
    path: PathBuf,
}

impl ReadyMarker {
    fn create(output_directory: &Path) -> Result<Self, ClientError> {
        let path = output_directory.join(READY_MARKER_NAME);
        std::fs::write(&path, b"ready\n").map_err(|error| {
            ClientError::new(
                "sleep_resume",
                "ready_marker_write_failed",
                Some(error.raw_os_error().unwrap_or(1) as u32),
            )
        })?;
        Ok(Self { path })
    }
}

impl Drop for ReadyMarker {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

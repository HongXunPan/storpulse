use storpulse_core::model::{Completeness, ProcessIdentity};
use storpulse_windows_service_contract::{ServiceMessage, decode_frame, encode_frame};
use storpulse_windows_service_runtime::{
    CollectorEvent, DiskOperation, ProcessDescriptor, ProcessMetrics, RuntimeError,
    SnapshotPublisher,
};

#[test]
fn mapped_disk_events_publish_process_and_device_totals() {
    let mut publisher = SnapshotPublisher::new();
    publisher.observe(CollectorEvent::ProcessObserved(process(42, 100)));
    publisher.observe(CollectorEvent::ThreadAssigned {
        thread_id: 7,
        process_id: 42,
    });
    publisher.observe(disk(0, 7, DiskOperation::Read, 4_096));
    publisher.observe(disk(0, 7, DiskOperation::Write, 8_192));

    let message = publisher
        .publish("2026-08-01T06:00:00Z".to_owned(), 1_000, 50)
        .unwrap();
    let frame = encode_frame(&message).unwrap();
    let message: ServiceMessage = decode_frame(&frame).unwrap();
    let ServiceMessage::Snapshot {
        sequence, snapshot, ..
    } = message
    else {
        panic!("应发布批量快照");
    };

    assert_eq!(sequence, 1);
    assert_eq!(snapshot.completeness, Completeness::Complete);
    assert_eq!(snapshot.processes[0].identity.start_time_ticks, 100);
    assert_eq!(snapshot.processes[0].read_bytes, 4_096);
    assert_eq!(snapshot.processes[0].write_bytes, 8_192);
    assert_eq!(snapshot.processes[0].resident_bytes, None);
    assert_eq!(snapshot.devices[0].device_id, "windows:disk:0");
    assert_eq!(snapshot.devices[0].read_operations, Some(1));
    assert_eq!(snapshot.devices[0].write_operations, Some(1));
}

#[test]
fn short_lived_process_survives_one_snapshot_and_pid_reuse_does_not_merge() {
    let mut publisher = SnapshotPublisher::new();
    publisher.observe(CollectorEvent::ProcessObserved(process(42, 100)));
    publisher.observe(CollectorEvent::ThreadAssigned {
        thread_id: 7,
        process_id: 42,
    });
    publisher.observe(disk(0, 7, DiskOperation::Read, 100));
    publisher.observe(CollectorEvent::ProcessEnded { process_id: 42 });
    publisher.observe(CollectorEvent::ProcessObserved(process(42, 200)));
    publisher.observe(CollectorEvent::ThreadAssigned {
        thread_id: 8,
        process_id: 42,
    });
    publisher.observe(disk(0, 8, DiskOperation::Read, 200));

    let first = snapshot(publisher.publish("t1".to_owned(), 1_000, 1).unwrap());
    assert_eq!(first.processes.len(), 2);
    assert_eq!(first.summary.exited_processes, 1);
    assert_eq!(first.processes[0].identity.start_time_ticks, 100);
    assert_eq!(first.processes[0].read_bytes, 100);
    assert_eq!(first.processes[1].identity.start_time_ticks, 200);
    assert_eq!(first.processes[1].read_bytes, 200);

    let second = snapshot(publisher.publish("t2".to_owned(), 2_000, 1).unwrap());
    assert_eq!(second.processes.len(), 1);
    assert_eq!(second.processes[0].identity.start_time_ticks, 200);
    assert_eq!(second.summary.exited_processes, 0);
}

#[test]
fn loss_restriction_and_unmapped_events_make_snapshot_partial() {
    let mut publisher = SnapshotPublisher::new();
    publisher.observe(CollectorEvent::ProcessRestricted { process_id: 4 });
    publisher.observe(disk(1, 99, DiskOperation::Read, 512));
    publisher.observe(CollectorEvent::TraceLoss {
        events: 2,
        buffers: 1,
    });

    let snapshot = snapshot(publisher.publish("t1".to_owned(), 1_000, 1).unwrap());
    assert_eq!(snapshot.completeness, Completeness::Partial);
    assert_eq!(snapshot.summary.restricted_processes, 1);
    assert_eq!(snapshot.summary.unmapped_disk_events, 1);
    assert_eq!(snapshot.summary.events_lost, 2);
    assert_eq!(snapshot.summary.buffers_lost, 1);
    assert_eq!(snapshot.devices[0].read_bytes, 512);
}

#[test]
fn publisher_rejects_non_monotonic_time_and_frames_round_trip() {
    let mut publisher = SnapshotPublisher::new();
    let first = publisher.publish("t1".to_owned(), 1_000, 1).unwrap();
    let frame = encode_frame(&first).unwrap();
    let decoded: ServiceMessage = decode_frame(&frame).unwrap();
    assert!(matches!(
        decoded,
        ServiceMessage::Snapshot { sequence: 1, .. }
    ));

    let error = publisher.publish("t2".to_owned(), 1_000, 1).unwrap_err();
    assert_eq!(
        error,
        RuntimeError::NonMonotonicPublish {
            previous: 1_000,
            received: 1_000,
        }
    );

    let payload = String::from_utf8(frame[4..].to_vec()).unwrap();
    assert!(!payload.contains("residentBytes"));
    assert!(!payload.contains("physicalFootprintBytes"));
    assert!(!payload.contains("path"));
}

fn process(pid: i32, start_time_ticks: u64) -> ProcessDescriptor {
    ProcessDescriptor {
        identity: ProcessIdentity {
            pid,
            start_time_ticks,
        },
        parent_pid: Some(1),
        executable_name: "worker.exe".to_owned(),
        metrics: ProcessMetrics::default(),
    }
}

fn disk(
    disk_number: u32,
    thread_id: u32,
    operation: DiskOperation,
    transfer_bytes: u64,
) -> CollectorEvent {
    CollectorEvent::DiskIo {
        disk_number,
        thread_id,
        operation,
        transfer_bytes,
    }
}

fn snapshot(message: ServiceMessage) -> Box<storpulse_core::model::RawSnapshot> {
    let ServiceMessage::Snapshot { snapshot, .. } = message else {
        panic!("应返回快照消息");
    };
    snapshot
}

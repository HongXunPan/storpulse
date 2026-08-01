use storpulse_core::model::{
    CollectionSummary, Completeness, DeviceIoSample, Freshness, MetricScope, RawSnapshot,
    SNAPSHOT_SCHEMA_VERSION,
};
use storpulse_windows_service_contract::{
    ClientMessage, CollectionSession, CollectionState, FailurePhase, FrameError,
    MAX_FRAME_PAYLOAD_BYTES, PROTOCOL_VERSION, SAMPLE_INTERVAL_MILLISECONDS, SafeErrorCode,
    ServiceMessage, SessionError, decode_frame, encode_frame,
};

#[test]
fn complete_collection_flow_preserves_versions_and_sequences() {
    let mut session = CollectionSession::default();
    session.begin_connecting().unwrap();
    session.observe(&ready()).unwrap();
    session
        .observe(&ServiceMessage::CollectionStarted {
            protocol_version: PROTOCOL_VERSION,
            first_sequence: 1,
        })
        .unwrap();
    session.observe(&snapshot_message(1, 1_000)).unwrap();
    session.observe(&snapshot_message(2, 2_000)).unwrap();
    session.request_stop().unwrap();
    session
        .observe(&ServiceMessage::Stopped {
            protocol_version: PROTOCOL_VERSION,
            final_sequence: Some(2),
        })
        .unwrap();

    assert_eq!(session.state(), CollectionState::Stopped);
    assert_eq!(session.last_sequence(), Some(2));
}

#[test]
fn protocol_and_snapshot_version_mismatch_enter_failed_state() {
    let mut protocol_mismatch = CollectionSession::default();
    protocol_mismatch.begin_connecting().unwrap();
    let error = protocol_mismatch
        .observe(&ServiceMessage::Ready {
            protocol_version: PROTOCOL_VERSION + 1,
            snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
            service_process_id: 4,
            sample_interval_milliseconds: SAMPLE_INTERVAL_MILLISECONDS,
        })
        .unwrap_err();
    assert_eq!(error, SessionError::UnsupportedProtocol(2));
    assert_eq!(protocol_mismatch.state(), CollectionState::Failed);

    let mut snapshot_mismatch = collecting_session();
    let mut snapshot = raw_snapshot(1_000);
    snapshot.schema_version = 1;
    let error = snapshot_mismatch
        .observe(&ServiceMessage::Snapshot {
            protocol_version: PROTOCOL_VERSION,
            sequence: 1,
            snapshot: Box::new(snapshot),
        })
        .unwrap_err();
    assert_eq!(error, SessionError::UnsupportedSnapshotSchema(1));
    assert_eq!(snapshot_mismatch.state(), CollectionState::Failed);

    let mut interval_mismatch = CollectionSession::default();
    interval_mismatch.begin_connecting().unwrap();
    let error = interval_mismatch
        .observe(&ServiceMessage::Ready {
            protocol_version: PROTOCOL_VERSION,
            snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
            service_process_id: 4,
            sample_interval_milliseconds: 999,
        })
        .unwrap_err();
    assert_eq!(error, SessionError::InvalidSampleInterval(999));
    assert_eq!(interval_mismatch.state(), CollectionState::Failed);
}

#[test]
fn sequence_gap_and_non_monotonic_time_are_rejected() {
    let mut gap = collecting_session();
    let error = gap.observe(&snapshot_message(2, 1_000)).unwrap_err();
    assert_eq!(
        error,
        SessionError::UnexpectedSequence {
            expected: 1,
            received: 2,
        }
    );

    let mut clock = collecting_session();
    clock.observe(&snapshot_message(1, 1_000)).unwrap();
    let error = clock.observe(&snapshot_message(2, 1_000)).unwrap_err();
    assert_eq!(error, SessionError::NonMonotonicSnapshot);
    assert_eq!(clock.state(), CollectionState::Failed);
}

#[test]
fn out_of_order_message_and_stop_mismatch_are_rejected() {
    let mut disconnected = CollectionSession::default();
    let error = disconnected.observe(&ready()).unwrap_err();
    assert_eq!(
        error,
        SessionError::InvalidTransition {
            state: CollectionState::Disconnected,
            message: "ready",
        }
    );

    let mut invalid_stop = CollectionSession::default();
    let error = invalid_stop.request_stop().unwrap_err();
    assert_eq!(
        error,
        SessionError::InvalidTransition {
            state: CollectionState::Disconnected,
            message: "stop_collection",
        }
    );
    assert_eq!(invalid_stop.state(), CollectionState::Failed);

    let mut draining = collecting_session();
    draining.observe(&snapshot_message(1, 1_000)).unwrap();
    draining.request_stop().unwrap();
    let error = draining
        .observe(&ServiceMessage::Stopped {
            protocol_version: PROTOCOL_VERSION,
            final_sequence: None,
        })
        .unwrap_err();
    assert_eq!(
        error,
        SessionError::StopSequenceMismatch {
            expected: Some(1),
            received: None,
        }
    );
}

#[test]
fn stable_failure_message_can_end_any_state() {
    let mut session = collecting_session();
    session
        .observe(&ServiceMessage::Failed {
            protocol_version: PROTOCOL_VERSION,
            phase: FailurePhase::Etw,
            safe_error_code: SafeErrorCode::EtwStartFailed,
            native_code: Some(5),
        })
        .unwrap();
    assert_eq!(session.state(), CollectionState::Failed);
}

#[test]
fn length_prefixed_frame_round_trips_with_camel_case_fields() {
    let message = ClientMessage::Connect {
        protocol_version: PROTOCOL_VERSION,
        snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
        run_id: "run-1".to_owned(),
        nonce: "00".repeat(32),
        client_process_id: 42,
    };
    let frame = encode_frame(&message).unwrap();
    let decoded: ClientMessage = decode_frame(&frame).unwrap();
    let payload = String::from_utf8(frame[4..].to_vec()).unwrap();

    assert_eq!(decoded.protocol_version(), PROTOCOL_VERSION);
    assert!(payload.contains("\"command\":\"connect\""));
    assert!(payload.contains("\"snapshotSchemaVersion\":2"));
    assert!(!payload.contains("snapshot_schema_version"));
}

#[test]
fn frame_rejects_oversized_and_incomplete_payloads() {
    let oversized = ((MAX_FRAME_PAYLOAD_BYTES + 1) as u32)
        .to_le_bytes()
        .to_vec();
    assert_eq!(
        decode_frame::<ClientMessage>(&oversized).unwrap_err(),
        FrameError::PayloadTooLarge {
            actual: MAX_FRAME_PAYLOAD_BYTES + 1,
            maximum: MAX_FRAME_PAYLOAD_BYTES,
        }
    );

    let mut incomplete = 10_u32.to_le_bytes().to_vec();
    incomplete.extend_from_slice(b"{}");
    assert_eq!(
        decode_frame::<ClientMessage>(&incomplete).unwrap_err(),
        FrameError::LengthMismatch {
            declared: 10,
            actual: 2,
        }
    );

    assert_eq!(
        decode_frame::<ClientMessage>(&[0, 1]).unwrap_err(),
        FrameError::HeaderMissing
    );
    let mut invalid_json = 1_u32.to_le_bytes().to_vec();
    invalid_json.push(b'x');
    assert_eq!(
        decode_frame::<ClientMessage>(&invalid_json).unwrap_err(),
        FrameError::InvalidJson
    );

    let command_with_path =
        br#"{"command":"start_collection","protocolVersion":1,"outputDirectory":"C:\\secret"}"#;
    assert_eq!(
        decode_frame::<ClientMessage>(&frame_from_payload(command_with_path)).unwrap_err(),
        FrameError::InvalidJson
    );
}

#[test]
fn snapshot_message_uses_windows_namespace_without_sensitive_fields() {
    let frame = encode_frame(&snapshot_message(1, 1_000)).unwrap();
    let payload = String::from_utf8(frame[4..].to_vec()).unwrap();

    assert!(payload.contains("\"deviceId\":\"windows:disk:0\""));
    assert!(!payload.contains("registryEntryId"));
    assert!(!payload.contains("commandLine"));
    assert!(!payload.contains("username"));
    assert!(!payload.contains("path"));

    let mut value = serde_json::to_value(snapshot_message(1, 1_000)).unwrap();
    value["snapshot"]["devices"][0]["path"] = serde_json::json!("C:\\secret");
    let payload = serde_json::to_vec(&value).unwrap();
    assert_eq!(
        decode_frame::<ServiceMessage>(&frame_from_payload(&payload)).unwrap_err(),
        FrameError::InvalidJson
    );
}

fn collecting_session() -> CollectionSession {
    let mut session = CollectionSession::default();
    session.begin_connecting().unwrap();
    session.observe(&ready()).unwrap();
    session
        .observe(&ServiceMessage::CollectionStarted {
            protocol_version: PROTOCOL_VERSION,
            first_sequence: 1,
        })
        .unwrap();
    session
}

fn ready() -> ServiceMessage {
    ServiceMessage::Ready {
        protocol_version: PROTOCOL_VERSION,
        snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
        service_process_id: 4,
        sample_interval_milliseconds: SAMPLE_INTERVAL_MILLISECONDS,
    }
}

fn snapshot_message(sequence: u64, monotonic_nanoseconds: u64) -> ServiceMessage {
    ServiceMessage::Snapshot {
        protocol_version: PROTOCOL_VERSION,
        sequence,
        snapshot: Box::new(raw_snapshot(monotonic_nanoseconds)),
    }
}

fn raw_snapshot(monotonic_nanoseconds: u64) -> RawSnapshot {
    RawSnapshot {
        schema_version: SNAPSHOT_SCHEMA_VERSION,
        captured_at: "2026-08-01T05:00:00Z".to_owned(),
        monotonic_nanoseconds,
        metric_source: "windows.localsystem-service.etw-system-diskio".to_owned(),
        metric_scope: vec![MetricScope::Device, MetricScope::StorageProcess],
        freshness: Freshness::Fresh,
        completeness: Completeness::Partial,
        processes: Vec::new(),
        devices: vec![DeviceIoSample {
            device_id: "windows:disk:0".to_owned(),
            read_bytes: 4_096,
            write_bytes: 8_192,
            read_operations: Some(1),
            write_operations: Some(2),
        }],
        summary: CollectionSummary {
            discovered_processes: 0,
            readable_processes: 0,
            restricted_processes: 0,
            exited_processes: 0,
            device_count: 1,
            collection_duration_nanoseconds: 1_000_000,
            unmapped_disk_events: 0,
            events_lost: 0,
            buffers_lost: 0,
        },
    }
}

fn frame_from_payload(payload: &[u8]) -> Vec<u8> {
    let mut frame = (payload.len() as u32).to_le_bytes().to_vec();
    frame.extend_from_slice(payload);
    frame
}

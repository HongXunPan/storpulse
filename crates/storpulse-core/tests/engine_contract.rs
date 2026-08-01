use storpulse_core::{
    ActivityPolicy, Engine, EngineCommand, EngineCommandResult, EngineError,
    model::{
        CollectionSummary, Completeness, DeviceIoSample, Freshness, MetricScope, ProcessIdentity,
        ProcessIoSample, RawSnapshot, SNAPSHOT_SCHEMA_VERSION,
    },
};

#[test]
fn rates_aggregation_and_running_totals_are_recomputable() {
    let mut engine = Engine::default();
    let first = engine
        .ingest(snapshot(1, 100, 200, 1_000, 2_000, 10))
        .unwrap();
    assert!(first.processes[0].current.is_none());
    assert!(first.devices[0].current.is_none());

    let second = engine
        .ingest(snapshot(2, 300, 500, 1_400, 2_600, 10))
        .unwrap();
    let process = &second.processes[0];
    assert_eq!(process.current.unwrap().read_bytes_per_second, 200.0);
    assert_eq!(process.current.unwrap().write_bytes_per_second, 300.0);
    assert_eq!(process.run_read_bytes, 200);
    assert_eq!(process.run_write_bytes, 300);
    assert_eq!(second.applications.len(), 1);
    assert_eq!(second.applications[0].helper_count, 1);
    assert_eq!(second.applications[0].run_write_bytes, 300);
    assert_eq!(second.schema_version, SNAPSHOT_SCHEMA_VERSION);
    assert_eq!(second.devices[0].device_id, "macos:ioreg:7");
}

#[test]
fn legacy_raw_snapshot_schema_is_rejected() {
    let mut legacy = snapshot(1, 100, 200, 1_000, 2_000, 10);
    legacy.schema_version = 1;

    let error = Engine::default().ingest(legacy).unwrap_err();
    assert_eq!(error, EngineError::UnsupportedSchema(1));
}

#[test]
fn pid_reuse_and_counter_reset_never_produce_negative_rate() {
    let mut engine = Engine::default();
    engine
        .ingest(snapshot(1, 100, 200, 1_000, 2_000, 10))
        .unwrap();
    let reused = engine
        .ingest(snapshot(2, 10, 20, 1_100, 2_100, 11))
        .unwrap();
    assert!(reused.processes[0].current.is_none());
    assert_eq!(reused.processes[0].run_write_bytes, 0);

    let reset = engine.ingest(snapshot(3, 1, 2, 1_200, 2_200, 11)).unwrap();
    assert!(reset.processes[0].current.is_none());
    assert_eq!(reset.processes[0].run_write_bytes, 0);
}

#[test]
fn stale_snapshot_removes_current_rates_but_keeps_totals() {
    let mut engine = Engine::default();
    engine
        .ingest(snapshot(1, 100, 200, 1_000, 2_000, 10))
        .unwrap();
    engine
        .ingest(snapshot(2, 300, 500, 1_400, 2_600, 10))
        .unwrap();

    let stale = engine.snapshot_at(6_000_000_001).unwrap();
    assert_eq!(stale.freshness, Freshness::Stale);
    assert!(stale.processes[0].current.is_none());
    assert!(stale.devices[0].current.is_none());
    assert_eq!(stale.processes[0].run_write_bytes, 300);
}

#[test]
fn observation_session_preserves_context_and_top_application() {
    let mut engine = Engine::default();
    engine
        .ingest(snapshot(1, 100, 200, 1_000, 2_000, 10))
        .unwrap();
    engine
        .execute(EngineCommand::StartObservation {
            session_id: "会话-1".to_owned(),
            started_at: "2026-07-30T10:00:00Z".to_owned(),
            monotonic_nanoseconds: 1_000_000_000,
        })
        .unwrap();
    engine
        .ingest(snapshot(2, 300, 500, 1_400, 2_600, 10))
        .unwrap();

    let result = engine
        .execute(EngineCommand::StopObservation {
            ended_at: "2026-07-30T10:00:02Z".to_owned(),
            monotonic_nanoseconds: 3_000_000_000,
        })
        .unwrap();
    let EngineCommandResult::ObservationStopped { session } = result else {
        panic!("应返回已结束会话");
    };
    assert_eq!(session.session_id, "会话-1");
    assert_eq!(session.write_bytes, 600);
    assert_eq!(
        session.top_applications[0].application_id,
        "com.example.editor"
    );
    assert_eq!(session.top_applications[0].write_bytes, 300);
}

#[test]
fn activity_policy_is_explicit_and_completed_activities_can_be_drained() {
    let mut engine = Engine::default();
    engine
        .execute(EngineCommand::ConfigureActivity {
            policy: ActivityPolicy {
                enabled: true,
                read_threshold_bytes_per_second: 50.0,
                write_threshold_bytes_per_second: 50.0,
                minimum_duration_milliseconds: 1_000,
            },
        })
        .unwrap();
    engine
        .ingest(snapshot(1, 100, 200, 1_000, 2_000, 10))
        .unwrap();
    engine
        .ingest(snapshot(2, 300, 500, 1_400, 2_600, 10))
        .unwrap();
    engine
        .ingest(snapshot(4, 300, 500, 1_400, 2_600, 10))
        .unwrap();

    let result = engine
        .execute(EngineCommand::DrainCompletedActivities)
        .unwrap();
    let EngineCommandResult::CompletedActivities { activities } = result else {
        panic!("应返回活动摘要");
    };
    assert_eq!(activities.len(), 1);
    assert_eq!(activities[0].application_id, "com.example.editor");
    assert!(activities[0].duration_milliseconds >= 2_000);
}

#[test]
fn swift_probe_fixture_decodes_without_platform_only_metadata() {
    let fixture = r#"{
      "schemaVersion":2,
      "capturedAt":"2026-07-30T10:00:00Z",
      "monotonicNanoseconds":1000000000,
      "metricSource":"macos.libproc-rusage-v4+iokit-block-storage",
      "metricScope":["device","storage_process"],
      "freshness":"fresh",
      "completeness":"restricted",
      "processes":[{"identity":{"pid":42,"startTimeTicks":9},"parentPid":1,
        "executableName":"示例","readBytes":100,"writeBytes":200,
        "userTimeNanoseconds":1,"systemTimeNanoseconds":2,
        "residentBytes":3,"physicalFootprintBytes":4}],
      "devices":[{"deviceId":"macos:ioreg:7","readBytes":1,
        "writeBytes":2,"readOperations":null,"writeOperations":null}],
      "summary":{"discoveredProcesses":1,"readableProcesses":1,
        "restrictedProcesses":0,"exitedProcesses":0,"deviceCount":0,
        "collectionDurationNanoseconds":20}
    }"#;
    let decoded: RawSnapshot = serde_json::from_str(fixture).unwrap();
    assert_eq!(
        decoded.processes[0].normalized_application_id(),
        "executable:示例"
    );
    assert_eq!(decoded.processes[0].parent_pid, Some(1));
    assert_eq!(decoded.devices[0].device_id, "macos:ioreg:7");
}

#[test]
fn command_json_uses_snake_case_type_and_camel_case_fields() {
    let command: EngineCommand = serde_json::from_str(
        r#"{"type":"start_observation","sessionId":"会话-2",
        "startedAt":"2026-07-30T10:00:00Z","monotonicNanoseconds":1}"#,
    )
    .unwrap();
    let EngineCommand::StartObservation { session_id, .. } = command else {
        panic!("应解析开始观察命令");
    };
    assert_eq!(session_id, "会话-2");
}

fn snapshot(
    second: u64,
    process_read: u64,
    process_write: u64,
    device_read: u64,
    device_write: u64,
    start_ticks: u64,
) -> RawSnapshot {
    RawSnapshot {
        schema_version: SNAPSHOT_SCHEMA_VERSION,
        captured_at: format!("2026-07-30T10:00:0{second}Z"),
        monotonic_nanoseconds: second * 1_000_000_000,
        metric_source: "macos.libproc-rusage-v4+iokit-block-storage".to_owned(),
        metric_scope: vec![MetricScope::Device, MetricScope::StorageProcess],
        freshness: Freshness::Fresh,
        completeness: Completeness::Restricted,
        processes: vec![ProcessIoSample {
            identity: ProcessIdentity {
                pid: 42,
                start_time_ticks: start_ticks,
            },
            parent_pid: Some(1),
            executable_name: "Editor Helper".to_owned(),
            application_id: Some("com.example.editor".to_owned()),
            application_name: Some("示例编辑器".to_owned()),
            is_helper: true,
            launched_by_application_id: None,
            read_bytes: process_read,
            write_bytes: process_write,
            user_time_nanoseconds: Some(0),
            system_time_nanoseconds: Some(0),
            resident_bytes: Some(0),
            physical_footprint_bytes: Some(10),
        }],
        devices: vec![DeviceIoSample {
            device_id: "macos:ioreg:7".to_owned(),
            read_bytes: device_read,
            write_bytes: device_write,
            read_operations: None,
            write_operations: None,
        }],
        summary: CollectionSummary {
            discovered_processes: 2,
            readable_processes: 1,
            restricted_processes: 1,
            exited_processes: 0,
            device_count: 1,
            collection_duration_nanoseconds: 10_000_000,
            unmapped_disk_events: 0,
            events_lost: 0,
            buffers_lost: 0,
        },
    }
}

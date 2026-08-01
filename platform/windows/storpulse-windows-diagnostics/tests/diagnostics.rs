use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use storpulse_windows_diagnostics::{
    DiagnosticContext, DiagnosticEvent, DiagnosticEventKind, DiagnosticEventRing,
    DiagnosticSeverity, DiagnosticState, ServiceFallbackStore, StorageError,
};
use storpulse_windows_service_contract::{FailurePhase, SafeErrorCode};

#[test]
fn safe_event_serialization_has_fixed_fields_without_sensitive_payloads() {
    let event = failure_event(10);
    let payload = serde_json::to_string(&event).unwrap();

    assert!(payload.contains("\"schemaVersion\":1"));
    assert!(payload.contains("\"safeErrorCode\":\"shutdown_failed\""));
    assert!(payload.contains("\"state\":\"failed\""));
    for forbidden in [
        "username",
        "sid",
        "path",
        "commandLine",
        "nonce",
        "token",
        "message",
        "stack",
    ] {
        assert!(!payload.contains(forbidden), "发现敏感字段：{forbidden}");
    }
}

#[test]
fn bounded_ring_evicts_only_the_oldest_event() {
    let context = DiagnosticContext::service("run-ring").unwrap();
    let mut ring = DiagnosticEventRing::with_capacity(2);
    for index in 0..3 {
        ring.push(DiagnosticEvent::service_lifecycle(
            &context,
            Duration::from_millis(index),
            DiagnosticEventKind::CollectionStarted,
            DiagnosticState::Collecting,
        ));
    }

    assert_eq!(ring.len(), 2);
    assert_eq!(ring.iter().next().unwrap().monotonic_milliseconds, 1);
    assert_eq!(ring.latest().unwrap().monotonic_milliseconds, 2);
}

#[test]
fn fallback_store_rotates_atomically_and_keeps_bounded_records() {
    let directory = TestDirectory::new("rotation");
    let store = ServiceFallbackStore::with_limits(directory.path(), 2, 64 * 1024);
    for timestamp in [1, 2, 3] {
        let event = failure_event(timestamp);
        store.write_failure(&event).unwrap();
    }

    let mut names = service_record_names(directory.path());
    names.sort();
    assert_eq!(names.len(), 2);
    assert!(names[0].starts_with("service-failure-00000000000000000002-"));
    assert!(names[1].starts_with("service-failure-00000000000000000003-"));
    assert!(fs::read_dir(directory.path()).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".writing")
    }));
}

#[test]
fn fallback_store_uses_a_bounded_suffix_for_same_timestamp() {
    let directory = TestDirectory::new("same-timestamp");
    let store = ServiceFallbackStore::with_limits(directory.path(), 2, 64 * 1024);
    let event = failure_event(7);

    store.write_failure(&event).unwrap();
    store.write_failure(&event).unwrap();

    let mut names = service_record_names(directory.path());
    names.sort();
    assert_eq!(names.len(), 2);
    assert!(names[0].ends_with("-00.ndjson"));
    assert!(names[1].ends_with("-01.ndjson"));
}

#[test]
fn storage_rejects_non_failure_oversize_and_unwritable_roots() {
    let directory = TestDirectory::new("failures");
    let context = DiagnosticContext::service("run-safe").unwrap();
    let information = DiagnosticEvent::service_lifecycle(
        &context,
        Duration::ZERO,
        DiagnosticEventKind::ServiceSessionCreated,
        DiagnosticState::Connecting,
    );
    let normal_store = ServiceFallbackStore::product(directory.path().join("normal"));
    assert_eq!(
        normal_store.write_failure(&information),
        Err(StorageError::NotTerminalFailure)
    );

    let small_store = ServiceFallbackStore::with_limits(directory.path().join("small"), 1, 8);
    assert_eq!(
        small_store.write_failure(&failure_event(4)),
        Err(StorageError::RecordTooLarge)
    );
    assert!(!directory.path().join("small").exists());

    let blocked_root = directory.path().join("blocked");
    fs::write(&blocked_root, b"file").unwrap();
    let blocked_store = ServiceFallbackStore::product(&blocked_root);
    assert_eq!(
        blocked_store.write_failure(&failure_event(5)),
        Err(StorageError::CreateDirectory)
    );
}

#[test]
fn in_memory_events_do_not_create_diagnostic_directories() {
    let directory = TestDirectory::new("memory-only");
    let root = directory.path().join("not-created");
    let context = DiagnosticContext::service("run-memory").unwrap();
    let mut ring = DiagnosticEventRing::default();
    ring.push(DiagnosticEvent::service_lifecycle(
        &context,
        Duration::ZERO,
        DiagnosticEventKind::ServiceSessionCreated,
        DiagnosticState::Connecting,
    ));

    assert_eq!(
        ring.latest().unwrap().severity,
        DiagnosticSeverity::Information
    );
    assert!(!root.exists());
}

fn failure_event(timestamp: u64) -> DiagnosticEvent {
    let context = DiagnosticContext::service("run-failure").unwrap();
    let mut event = DiagnosticEvent::service_failure(
        &context,
        Duration::from_millis(timestamp),
        FailurePhase::Shutdown,
        SafeErrorCode::ShutdownFailed,
        Some(5),
    );
    event.timestamp_utc = timestamp;
    event
}

fn service_record_names(directory: &Path) -> Vec<String> {
    fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("service-failure-") && name.ends_with(".ndjson"))
        .collect()
}

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(name: &str) -> Self {
        let path = std::env::current_dir()
            .unwrap()
            .join(".codex-tmp")
            .join("windows-diagnostics-tests")
            .join(format!("{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

use std::path::PathBuf;

use serde::Serialize;

#[derive(Debug, Clone)]
pub struct GateOptions {
    pub output_directory: PathBuf,
    pub run_id: String,
    pub duration_seconds: u64,
    pub mode: GateMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GateMode {
    ContinuousValidation,
    DisconnectCleanup,
    ConnectTimeoutCleanup,
    ClientTerminationCleanup,
    SleepResumeValidation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GateStatus {
    Completed,
    Restricted,
    Failed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SafeFailure {
    pub phase: &'static str,
    pub safe_error_code: &'static str,
    pub native_code: Option<u32>,
}

impl SafeFailure {
    #[cfg(windows)]
    pub(crate) fn new(
        phase: &'static str,
        safe_error_code: &'static str,
        native_code: Option<u32>,
    ) -> Self {
        Self {
            phase,
            safe_error_code,
            native_code,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotEvidence {
    pub snapshot_count: u64,
    pub first_sequence: Option<u64>,
    pub last_sequence: Option<u64>,
    pub final_sequence: Option<u64>,
    pub complete_snapshots: u64,
    pub partial_snapshots: u64,
    pub restricted_snapshots: u64,
    pub max_processes: usize,
    pub max_restricted_processes: usize,
    pub max_devices: usize,
    pub client_process_observed: bool,
    pub client_read_bytes: u64,
    pub client_write_bytes: u64,
    pub device_read_bytes: u64,
    pub device_write_bytes: u64,
    pub unmapped_disk_events: u64,
    pub events_lost: u64,
    pub buffers_lost: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkloadEvidence {
    pub attempted: bool,
    pub completed: bool,
    pub write_bytes: u64,
    pub read_bytes: u64,
    pub read_mode: Option<&'static str>,
    pub cleanup_succeeded: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SleepResumeEvidence {
    pub ready_for_sleep: bool,
    pub suspend_detected: bool,
    pub resume_detected: bool,
    pub estimated_sleep_milliseconds: u64,
    pub sequence_continuity_confirmed: bool,
    pub pre_sleep_snapshots: SnapshotEvidence,
    pub post_resume_snapshots: SnapshotEvidence,
    pub post_resume_workload: WorkloadEvidence,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GateReport {
    pub schema_version: u32,
    pub run_id: String,
    pub mode: GateMode,
    pub status: GateStatus,
    pub outcome: &'static str,
    pub service_name: &'static str,
    pub client_process_id: u32,
    pub client_elevated: Option<bool>,
    pub service_process_id: Option<u32>,
    pub service_win32_exit_code: Option<u32>,
    pub service_specific_exit_code: Option<u32>,
    pub protocol_completed: bool,
    pub service_stopped: bool,
    pub disconnect_cleanup_confirmed: bool,
    pub connect_timeout_confirmed: bool,
    pub client_termination_cleanup_confirmed: bool,
    pub sleep_resume_confirmed: bool,
    pub snapshots: SnapshotEvidence,
    pub workload: WorkloadEvidence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sleep_resume: Option<SleepResumeEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<SafeFailure>,
    pub limitations: Vec<&'static str>,
}

impl GateReport {
    #[cfg(windows)]
    pub(crate) fn new(options: &GateOptions, service_name: &'static str) -> Self {
        Self {
            schema_version: 1,
            run_id: options.run_id.clone(),
            mode: options.mode,
            status: GateStatus::Failed,
            outcome: "windows_continuous_gate_failed",
            service_name,
            client_process_id: std::process::id(),
            client_elevated: None,
            service_process_id: None,
            service_win32_exit_code: None,
            service_specific_exit_code: None,
            protocol_completed: false,
            service_stopped: false,
            disconnect_cleanup_confirmed: false,
            connect_timeout_confirmed: false,
            client_termination_cleanup_confirmed: false,
            sleep_resume_confirmed: false,
            snapshots: SnapshotEvidence::default(),
            workload: WorkloadEvidence::default(),
            sleep_resume: (options.mode == GateMode::SleepResumeValidation)
                .then(SleepResumeEvidence::default),
            failure: None,
            limitations: limitations(options.mode),
        }
    }

    pub fn succeeded(&self) -> bool {
        self.status == GateStatus::Completed
    }
}

#[cfg(windows)]
fn limitations(mode: GateMode) -> Vec<&'static str> {
    let mut limitations = vec![
        "Windows 10 结果不能替代 Windows 11、签名、安装器或长期运行门禁",
        "诊断只保存聚合证据，不保存原始快照、路径、命令行、用户名、SID 或 nonce",
    ];
    if mode == GateMode::SleepResumeValidation {
        limitations.push("一次手动休眠恢复不能替代现代待机、休眠、多用户或长期运行验证");
    } else {
        limitations.push("单次受控负载不能替代休眠恢复、强杀和多用户验证");
    }
    limitations
}

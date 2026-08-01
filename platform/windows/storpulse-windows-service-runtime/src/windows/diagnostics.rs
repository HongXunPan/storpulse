use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use storpulse_windows_diagnostics::{
    DiagnosticContext, DiagnosticEvent, DiagnosticEventKind, DiagnosticEventRing, DiagnosticState,
    ServiceFallbackStore, program_data_diagnostics_root,
};

use super::ServiceRunError;

pub(super) struct ServiceDiagnostics {
    context: DiagnosticContext,
    started: Instant,
    events: DiagnosticEventRing,
}

impl ServiceDiagnostics {
    pub(super) fn start() -> Self {
        let context = DiagnosticContext::service(generated_run_id())
            .expect("固定服务运行标识必须符合诊断安全格式");
        let mut diagnostics = Self {
            context,
            started: Instant::now(),
            events: DiagnosticEventRing::service_default(),
        };
        diagnostics.record(
            DiagnosticEventKind::ServiceSessionCreated,
            DiagnosticState::Connecting,
        );
        diagnostics
    }

    pub(super) fn associate_run_id(&mut self, run_id: &str) {
        let result = self.context.replace_run_id(run_id.to_owned());
        debug_assert!(result.is_ok(), "服务协议已经验证运行标识");
    }

    pub(super) fn record(&mut self, event: DiagnosticEventKind, state: DiagnosticState) {
        self.events.push(DiagnosticEvent::service_lifecycle(
            &self.context,
            self.started.elapsed(),
            event,
            state,
        ));
    }

    pub(super) fn record_failure(&mut self, error: ServiceRunError) {
        self.events.push(DiagnosticEvent::service_failure(
            &self.context,
            self.started.elapsed(),
            error.phase,
            error.safe_error_code,
            error.native_code,
        ));
    }

    pub(super) fn persist_latest_failure(&self) {
        let Some(event) = self.events.latest() else {
            return;
        };
        let Some(directory) = fallback_directory() else {
            return;
        };
        let _ = ServiceFallbackStore::product(directory).write_failure(event);
    }
}

fn fallback_directory() -> Option<PathBuf> {
    let program_data = std::env::var_os("ProgramData")?;
    program_data_diagnostics_root(PathBuf::from(program_data).as_path())
}

fn generated_run_id() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis();
    format!("service-{timestamp}-{}", std::process::id())
}

mod model;

#[cfg(windows)]
mod windows;

pub use model::{
    GateMode, GateOptions, GateReport, GateStatus, SafeFailure, SleepResumeEvidence,
    SnapshotEvidence, WorkloadEvidence,
};

#[cfg(windows)]
pub use windows::run_gate;

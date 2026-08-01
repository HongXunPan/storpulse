mod clock;
mod diagnostics;
mod etw;
mod identity;
mod service_error;
mod service_loop;
mod trace;
mod trace_config;

pub use etw::{EtwCallbackContext, event_record_callback};
pub use service_error::ServiceRunError;
pub use service_loop::{ServiceOutcome, run_single_session, run_single_session_with_ready};
pub use storpulse_windows_ipc::{PRODUCT_PIPE_NAME, PipeError, PipeErrorKind, ProductPipe};
pub use trace::{TraceCompletion, TraceError, TraceSession};
pub use trace_config::PRODUCT_ETW_SESSION_NAME;

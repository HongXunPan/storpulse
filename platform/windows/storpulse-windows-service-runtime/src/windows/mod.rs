mod clock;
mod etw;
mod identity;
mod pipe;
mod pipe_support;
mod service_error;
mod service_loop;
mod trace;
mod trace_config;

pub use etw::{EtwCallbackContext, event_record_callback};
pub use pipe::{PRODUCT_PIPE_NAME, ProductPipe};
pub use pipe_support::{PipeError, PipeErrorKind};
pub use service_error::ServiceRunError;
pub use service_loop::{ServiceOutcome, run_single_session, run_single_session_with_ready};
pub use trace::{TraceCompletion, TraceError, TraceSession};
pub use trace_config::PRODUCT_ETW_SESSION_NAME;

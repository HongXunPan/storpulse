mod frame;
mod message;
mod server;
mod session;

pub use frame::{FrameError, decode_frame, encode_frame};
pub use message::{ClientMessage, FailurePhase, SafeErrorCode, ServiceMessage};
pub use server::{ConnectionRequest, ServiceCommandSession, ServiceSessionError};
pub use session::{CollectionSession, CollectionState, SessionError};
pub use storpulse_core::model::SNAPSHOT_SCHEMA_VERSION;

pub const PROTOCOL_VERSION: u32 = 1;
pub const SAMPLE_INTERVAL_MILLISECONDS: u64 = 1_000;
pub const MAX_FRAME_PAYLOAD_BYTES: usize = 1_048_576;

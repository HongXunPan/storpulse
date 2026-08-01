use std::fmt::{Display, Formatter};

use serde::{Serialize, de::DeserializeOwned};

use crate::MAX_FRAME_PAYLOAD_BYTES;

const FRAME_HEADER_BYTES: usize = size_of::<u32>();

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    PayloadTooLarge { actual: usize, maximum: usize },
    HeaderMissing,
    LengthMismatch { declared: usize, actual: usize },
    InvalidJson,
}

impl Display for FrameError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PayloadTooLarge { actual, maximum } => {
                write!(formatter, "协议负载过大：{actual} > {maximum}")
            }
            Self::HeaderMissing => formatter.write_str("协议帧缺少长度头"),
            Self::LengthMismatch { declared, actual } => {
                write!(
                    formatter,
                    "协议帧长度不一致：声明 {declared}，实际 {actual}"
                )
            }
            Self::InvalidJson => formatter.write_str("协议帧 JSON 无效"),
        }
    }
}

impl std::error::Error for FrameError {}

pub fn encode_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, FrameError> {
    let payload = serde_json::to_vec(value).map_err(|_| FrameError::InvalidJson)?;
    validate_payload_size(payload.len())?;

    let mut frame = Vec::with_capacity(FRAME_HEADER_BYTES + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

pub fn decode_frame<T: DeserializeOwned>(frame: &[u8]) -> Result<T, FrameError> {
    if frame.len() < FRAME_HEADER_BYTES {
        return Err(FrameError::HeaderMissing);
    }
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    header.copy_from_slice(&frame[..FRAME_HEADER_BYTES]);
    let declared = u32::from_le_bytes(header);
    let declared = declared as usize;
    validate_payload_size(declared)?;

    let payload = &frame[FRAME_HEADER_BYTES..];
    if payload.len() != declared {
        return Err(FrameError::LengthMismatch {
            declared,
            actual: payload.len(),
        });
    }
    serde_json::from_slice(payload).map_err(|_| FrameError::InvalidJson)
}

fn validate_payload_size(actual: usize) -> Result<(), FrameError> {
    if actual > MAX_FRAME_PAYLOAD_BYTES {
        return Err(FrameError::PayloadTooLarge {
            actual,
            maximum: MAX_FRAME_PAYLOAD_BYTES,
        });
    }
    Ok(())
}

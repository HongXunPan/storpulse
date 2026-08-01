use std::fmt::{Display, Formatter};
use std::mem::size_of;

use crate::{CollectorEvent, DiskOperation};

const THREAD_PROCESS_ID_OFFSET: usize = 0;
const THREAD_ID_OFFSET: usize = 4;
const DISK_NUMBER_OFFSET: usize = 0;
const DISK_TRANSFER_SIZE_OFFSET: usize = 8;
const DISK_THREAD_ID_32_OFFSET: usize = 40;
const DISK_THREAD_ID_64_OFFSET: usize = 48;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClassicProvider {
    Process,
    Thread,
    DiskIo,
    Other,
}

#[derive(Debug, Clone, Copy)]
pub struct ClassicEvent<'a> {
    pub provider: ClassicProvider,
    pub opcode: u8,
    pub pointer_bytes: usize,
    pub payload: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClassicEventDecodeError {
    UnsupportedPointerWidth(usize),
    ShortPayload {
        field: &'static str,
        required: usize,
        actual: usize,
    },
    ProcessIdOutOfRange(u32),
}

impl Display for ClassicEventDecodeError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedPointerWidth(width) => {
                write!(formatter, "不支持的 ETW 指针宽度：{width}")
            }
            Self::ShortPayload {
                field,
                required,
                actual,
            } => write!(
                formatter,
                "ETW 字段 {field} 负载过短：需要 {required}，实际 {actual}"
            ),
            Self::ProcessIdOutOfRange(process_id) => {
                write!(formatter, "ETW 进程标识超出共享契约范围：{process_id}")
            }
        }
    }
}

impl std::error::Error for ClassicEventDecodeError {}

pub fn decode_classic_event(
    event: ClassicEvent<'_>,
) -> Result<Option<CollectorEvent>, ClassicEventDecodeError> {
    match event.provider {
        ClassicProvider::Thread => decode_thread(event),
        ClassicProvider::DiskIo => decode_disk(event),
        ClassicProvider::Process | ClassicProvider::Other => Ok(None),
    }
}

fn decode_thread(
    event: ClassicEvent<'_>,
) -> Result<Option<CollectorEvent>, ClassicEventDecodeError> {
    if !matches!(event.opcode, 1..=4) {
        return Ok(None);
    }
    let process_id = process_id(read_u32(
        event.payload,
        THREAD_PROCESS_ID_OFFSET,
        "thread.process_id",
    )?)?;
    let thread_id = read_u32(event.payload, THREAD_ID_OFFSET, "thread.thread_id")?;
    let decoded = match event.opcode {
        1 | 3 => CollectorEvent::ThreadAssigned {
            thread_id,
            process_id,
        },
        2 | 4 => CollectorEvent::ThreadEnded { thread_id },
        _ => unreachable!(),
    };
    Ok(Some(decoded))
}

fn decode_disk(event: ClassicEvent<'_>) -> Result<Option<CollectorEvent>, ClassicEventDecodeError> {
    let operation = match event.opcode {
        10 => DiskOperation::Read,
        11 => DiskOperation::Write,
        _ => return Ok(None),
    };
    let thread_offset = match event.pointer_bytes {
        4 => DISK_THREAD_ID_32_OFFSET,
        8 => DISK_THREAD_ID_64_OFFSET,
        width => return Err(ClassicEventDecodeError::UnsupportedPointerWidth(width)),
    };
    Ok(Some(CollectorEvent::DiskIo {
        disk_number: read_u32(event.payload, DISK_NUMBER_OFFSET, "disk.disk_number")?,
        thread_id: read_u32(event.payload, thread_offset, "disk.issuing_thread_id")?,
        operation,
        transfer_bytes: u64::from(read_u32(
            event.payload,
            DISK_TRANSFER_SIZE_OFFSET,
            "disk.transfer_size",
        )?),
    }))
}

fn read_u32(
    payload: &[u8],
    offset: usize,
    field: &'static str,
) -> Result<u32, ClassicEventDecodeError> {
    let required = offset + size_of::<u32>();
    let bytes = payload
        .get(offset..required)
        .ok_or(ClassicEventDecodeError::ShortPayload {
            field,
            required,
            actual: payload.len(),
        })?;
    Ok(u32::from_le_bytes(
        bytes.try_into().expect("字段长度已验证"),
    ))
}

fn process_id(value: u32) -> Result<i32, ClassicEventDecodeError> {
    i32::try_from(value).map_err(|_| ClassicEventDecodeError::ProcessIdOutOfRange(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_thread_lifecycle_from_payload_identity() {
        let mut payload = [0_u8; 8];
        payload[..4].copy_from_slice(&42_u32.to_le_bytes());
        payload[4..].copy_from_slice(&7_u32.to_le_bytes());

        let assigned = decode(ClassicProvider::Thread, 1, 8, &payload).unwrap();
        let ended = decode(ClassicProvider::Thread, 2, 8, &payload).unwrap();

        assert_eq!(
            assigned,
            Some(CollectorEvent::ThreadAssigned {
                thread_id: 7,
                process_id: 42,
            })
        );
        assert_eq!(ended, Some(CollectorEvent::ThreadEnded { thread_id: 7 }));
    }

    #[test]
    fn decodes_disk_number_size_and_issuing_thread_for_both_widths() {
        for (pointer_bytes, thread_offset) in [(4, 40), (8, 48)] {
            let mut payload = vec![0_u8; thread_offset + 4];
            payload[..4].copy_from_slice(&2_u32.to_le_bytes());
            payload[8..12].copy_from_slice(&4_096_u32.to_le_bytes());
            payload[thread_offset..thread_offset + 4].copy_from_slice(&7_u32.to_le_bytes());

            assert_eq!(
                decode(ClassicProvider::DiskIo, 11, pointer_bytes, &payload).unwrap(),
                Some(CollectorEvent::DiskIo {
                    disk_number: 2,
                    thread_id: 7,
                    operation: DiskOperation::Write,
                    transfer_bytes: 4_096,
                })
            );
        }
    }

    #[test]
    fn rejects_short_disk_payload_instead_of_guessing_thread() {
        let error = decode(ClassicProvider::DiskIo, 10, 8, &[0_u8; 48]).unwrap_err();

        assert_eq!(
            error,
            ClassicEventDecodeError::ShortPayload {
                field: "disk.issuing_thread_id",
                required: 52,
                actual: 48,
            }
        );
    }

    #[test]
    fn ignores_unowned_provider_and_unknown_opcode() {
        assert_eq!(decode(ClassicProvider::Other, 10, 8, &[]).unwrap(), None);
        assert_eq!(decode(ClassicProvider::DiskIo, 12, 8, &[]).unwrap(), None);
    }

    fn decode(
        provider: ClassicProvider,
        opcode: u8,
        pointer_bytes: usize,
        payload: &[u8],
    ) -> Result<Option<CollectorEvent>, ClassicEventDecodeError> {
        decode_classic_event(ClassicEvent {
            provider,
            opcode,
            pointer_bytes,
            payload,
        })
    }
}

use std::mem::{offset_of, size_of};

use windows_sys::Win32::System::Diagnostics::Etw::{
    EVENT_TRACE_FLAG_DISK_IO, EVENT_TRACE_FLAG_DISK_IO_INIT, EVENT_TRACE_FLAG_PROCESS,
    EVENT_TRACE_FLAG_THREAD, EVENT_TRACE_PROPERTIES, EVENT_TRACE_REAL_TIME_MODE,
    EVENT_TRACE_SYSTEM_LOGGER_MODE, WNODE_FLAG_TRACED_GUID,
};

pub const PRODUCT_ETW_SESSION_NAME: &str = "StorPulse.Collector.Etw.v1";

#[repr(C)]
pub(super) struct TracePropertiesBuffer {
    pub(super) properties: EVENT_TRACE_PROPERTIES,
    logger_name: [u16; 128],
}

impl TracePropertiesBuffer {
    pub(super) fn new(session_name: &[u16]) -> Self {
        let mut value = Self {
            properties: EVENT_TRACE_PROPERTIES::default(),
            logger_name: [0; 128],
        };
        let copied = session_name.len().min(value.logger_name.len());
        value.logger_name[..copied].copy_from_slice(&session_name[..copied]);
        value.properties.Wnode.BufferSize = size_of::<Self>() as u32;
        value.properties.Wnode.ClientContext = 1;
        value.properties.Wnode.Flags = WNODE_FLAG_TRACED_GUID;
        value.properties.BufferSize = 64;
        value.properties.MinimumBuffers = 4;
        value.properties.MaximumBuffers = 64;
        value.properties.LogFileMode = EVENT_TRACE_REAL_TIME_MODE | EVENT_TRACE_SYSTEM_LOGGER_MODE;
        value.properties.FlushTimer = 1;
        value.properties.EnableFlags = EVENT_TRACE_FLAG_DISK_IO
            | EVENT_TRACE_FLAG_DISK_IO_INIT
            | EVENT_TRACE_FLAG_PROCESS
            | EVENT_TRACE_FLAG_THREAD;
        value.properties.LoggerNameOffset = offset_of!(Self, logger_name) as u32;
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_trace_uses_custom_system_logger_and_expected_flags() {
        let name: Vec<u16> = PRODUCT_ETW_SESSION_NAME
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let properties = TracePropertiesBuffer::new(&name);

        assert_eq!(properties.properties.Wnode.Guid.data1, 0);
        assert_ne!(
            properties.properties.LogFileMode & EVENT_TRACE_SYSTEM_LOGGER_MODE,
            0
        );
        assert_ne!(
            properties.properties.EnableFlags & EVENT_TRACE_FLAG_DISK_IO,
            0
        );
        assert_ne!(
            properties.properties.EnableFlags & EVENT_TRACE_FLAG_PROCESS,
            0
        );
    }
}

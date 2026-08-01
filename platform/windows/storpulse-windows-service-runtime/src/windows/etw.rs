use std::mem::size_of;
use std::slice;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError};

use storpulse_core::model::ProcessIdentity;
use windows_sys::Win32::Foundation::{CloseHandle, ERROR_SUCCESS, FILETIME};
use windows_sys::Win32::System::Diagnostics::Etw::{
    DiskIoGuid, EVENT_HEADER_FLAG_32_BIT_HEADER, EVENT_RECORD, PROPERTY_DATA_DESCRIPTOR,
    ProcessGuid, TdhGetProperty, TdhGetPropertySize, ThreadGuid,
};
use windows_sys::Win32::System::Threading::{
    GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
};

use crate::{
    ClassicEvent, ClassicEventDecodeError, ClassicProvider, CollectorEvent, ProcessDescriptor,
    ProcessMetrics, decode_classic_event,
};

const MAX_PROCESS_NAME_BYTES: u32 = 1_024;

pub struct EtwCallbackContext {
    sender: SyncSender<CollectorEvent>,
    dropped_events: AtomicU64,
}

impl EtwCallbackContext {
    pub fn new(sender: SyncSender<CollectorEvent>) -> Arc<Self> {
        Arc::new(Self {
            sender,
            dropped_events: AtomicU64::new(0),
        })
    }

    pub fn user_context(context: &Arc<Self>) -> *mut core::ffi::c_void {
        Arc::as_ptr(context).cast_mut().cast()
    }

    pub fn take_channel_loss(&self) -> Option<CollectorEvent> {
        let events = self.dropped_events.swap(0, Ordering::AcqRel);
        (events > 0).then_some(CollectorEvent::TraceLoss { events, buffers: 0 })
    }

    fn emit(&self, event: CollectorEvent) {
        if matches!(
            self.sender.try_send(event),
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_))
        ) {
            self.record_loss();
        }
    }

    fn record_loss(&self) {
        self.dropped_events.fetch_add(1, Ordering::Relaxed);
    }
}

/// # 安全性
///
/// `event_record` 必须由 ETW 在回调有效期内提供，且 `UserContext` 必须指向仍存活的
/// `EtwCallbackContext`。调用方必须等 `ProcessTrace` 返回后才能释放该上下文。
pub unsafe extern "system" fn event_record_callback(event_record: *mut EVENT_RECORD) {
    if event_record.is_null() {
        return;
    }
    // SAFETY：ETW 保证回调期间事件记录有效。
    let event = unsafe { &*event_record };
    if event.UserContext.is_null() {
        return;
    }
    // SAFETY：调用方按函数契约让 Arc 上下文存活至 ProcessTrace 返回。
    let context = unsafe { &*(event.UserContext as *const EtwCallbackContext) };
    match decode_event_record(event) {
        Ok(Some(decoded)) => context.emit(decoded),
        Ok(None) => {}
        Err(()) => context.record_loss(),
    }
}

fn decode_event_record(event: &EVENT_RECORD) -> Result<Option<CollectorEvent>, ()> {
    let provider = provider(&event.EventHeader.ProviderId);
    if provider == ClassicProvider::Process {
        return decode_process_event(event);
    }
    if provider == ClassicProvider::Other {
        return Ok(None);
    }
    let payload = event_payload(event)?;
    let pointer_bytes = if u32::from(event.EventHeader.Flags) & EVENT_HEADER_FLAG_32_BIT_HEADER != 0
    {
        4
    } else {
        8
    };
    decode_classic_event(ClassicEvent {
        provider,
        opcode: event.EventHeader.EventDescriptor.Opcode,
        pointer_bytes,
        payload,
    })
    .map_err(|_: ClassicEventDecodeError| ())
}

fn decode_process_event(event: &EVENT_RECORD) -> Result<Option<CollectorEvent>, ()> {
    let opcode = event.EventHeader.EventDescriptor.Opcode;
    if !matches!(opcode, 1 | 2 | 3 | 4 | 39) {
        return Ok(None);
    }
    let process_id_u32 = read_tdh_u32(event, "ProcessId")?;
    if process_id_u32 == 0 {
        return Ok(None);
    }
    let process_id = i32::try_from(process_id_u32).map_err(|_| ())?;
    if matches!(opcode, 2 | 4 | 39) {
        return Ok(Some(CollectorEvent::ProcessEnded { process_id }));
    }

    let parent_pid = read_tdh_u32(event, "ParentId")
        .ok()
        .and_then(|value| i32::try_from(value).ok())
        .filter(|value| *value > 0);
    let Some(executable_name) = read_process_name(event) else {
        return Ok(Some(CollectorEvent::ProcessRestricted { process_id }));
    };
    let start_time_ticks = process_start_time(process_id_u32).or_else(|| {
        (opcode == 1)
            .then(|| u64::try_from(event.EventHeader.TimeStamp).ok())
            .flatten()
            .filter(|value| *value > 0)
    });
    let Some(start_time_ticks) = start_time_ticks else {
        return Ok(Some(CollectorEvent::ProcessRestricted { process_id }));
    };

    Ok(Some(CollectorEvent::ProcessObserved(ProcessDescriptor {
        identity: ProcessIdentity {
            pid: process_id,
            start_time_ticks,
        },
        parent_pid,
        executable_name,
        metrics: ProcessMetrics::default(),
    })))
}

fn event_payload(event: &EVENT_RECORD) -> Result<&[u8], ()> {
    let length = usize::from(event.UserDataLength);
    if length == 0 {
        return Ok(&[]);
    }
    if event.UserData.is_null() {
        return Err(());
    }
    // SAFETY：ETW 保证 UserData 在回调期间至少包含 UserDataLength 字节。
    Ok(unsafe { slice::from_raw_parts(event.UserData.cast::<u8>(), length) })
}

fn read_tdh_u32(event: &EVENT_RECORD, name: &str) -> Result<u32, ()> {
    let bytes = read_tdh_property(event, name, size_of::<u32>() as u32)?;
    let bytes: [u8; 4] = bytes.as_slice().try_into().map_err(|_| ())?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_process_name(event: &EVENT_RECORD) -> Option<String> {
    let bytes = read_tdh_property(event, "ImageFileName", MAX_PROCESS_NAME_BYTES).ok()?;
    let length = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    let raw = String::from_utf8_lossy(&bytes[..length]);
    raw.rsplit(['\\', '/'])
        .find(|part| !part.is_empty())
        .map(|part| part.chars().take(260).collect())
        .filter(|name: &String| !name.is_empty())
}

fn read_tdh_property(event: &EVENT_RECORD, name: &str, maximum: u32) -> Result<Vec<u8>, ()> {
    let wide_name: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let descriptor = PROPERTY_DATA_DESCRIPTOR {
        PropertyName: wide_name.as_ptr() as u64,
        ArrayIndex: u32::MAX,
        Reserved: 0,
    };
    let mut size = 0;
    // SAFETY：事件记录和属性名称在两次同步 TDH 调用期间有效。
    let status =
        unsafe { TdhGetPropertySize(event, 0, std::ptr::null(), 1, &descriptor, &mut size) };
    if status != ERROR_SUCCESS || size == 0 || size > maximum {
        return Err(());
    }
    let mut value = vec![0_u8; size as usize];
    // SAFETY：value 已按 TDH 返回大小分配，所有输入指针在调用期间有效。
    let status = unsafe {
        TdhGetProperty(
            event,
            0,
            std::ptr::null(),
            1,
            &descriptor,
            size,
            value.as_mut_ptr(),
        )
    };
    (status == ERROR_SUCCESS).then_some(value).ok_or(())
}

fn process_start_time(process_id: u32) -> Option<u64> {
    // SAFETY：只申请受限查询权限，不继承句柄。
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) };
    if handle.is_null() {
        return None;
    }
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // SAFETY：进程句柄有效，四个 FILETIME 输出缓冲区均有效。
    let succeeded =
        unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) } != 0;
    // SAFETY：handle 由 OpenProcess 返回，只关闭一次。
    unsafe { CloseHandle(handle) };
    succeeded.then_some(filetime_ticks(creation))
}

fn filetime_ticks(value: FILETIME) -> u64 {
    u64::from(value.dwLowDateTime) | (u64::from(value.dwHighDateTime) << 32)
}

fn provider(value: &windows_sys::core::GUID) -> ClassicProvider {
    if same_guid(value, &ProcessGuid) {
        ClassicProvider::Process
    } else if same_guid(value, &ThreadGuid) {
        ClassicProvider::Thread
    } else if same_guid(value, &DiskIoGuid) {
        ClassicProvider::DiskIo
    } else {
        ClassicProvider::Other
    }
}

fn same_guid(left: &windows_sys::core::GUID, right: &windows_sys::core::GUID) -> bool {
    left.data1 == right.data1
        && left.data2 == right.data2
        && left.data3 == right.data3
        && left.data4 == right.data4
}

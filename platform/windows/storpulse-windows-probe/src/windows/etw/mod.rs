mod events;

use std::mem::{offset_of, size_of};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use windows_sys::Win32::Foundation::{ERROR_CANCELLED, ERROR_SUCCESS, GetLastError};
use windows_sys::Win32::System::Diagnostics::Etw::{
    CONTROLTRACE_HANDLE, CloseTrace, ControlTraceW, EVENT_TRACE_CONTROL_STOP,
    EVENT_TRACE_FLAG_DISK_IO, EVENT_TRACE_FLAG_DISK_IO_INIT, EVENT_TRACE_FLAG_PROCESS,
    EVENT_TRACE_FLAG_THREAD, EVENT_TRACE_LOGFILEW, EVENT_TRACE_PROPERTIES,
    EVENT_TRACE_REAL_TIME_MODE, EVENT_TRACE_SYSTEM_LOGGER_MODE, OpenTraceW,
    PROCESS_TRACE_MODE_EVENT_RECORD, PROCESS_TRACE_MODE_REAL_TIME, ProcessTrace, StartTraceW,
    SystemTraceControlGuid, WNODE_FLAG_TRACED_GUID,
};

use crate::model::EtwEventReport;

use self::events::{CallbackContext, EventStats, SessionCompletion, event_record_callback};
use super::NativeFailure;

const INVALID_PROCESSTRACE_HANDLE: u64 = u64::MAX;

#[repr(C)]
struct TracePropertiesBuffer {
    properties: EVENT_TRACE_PROPERTIES,
    logger_name: [u16; 128],
}

impl TracePropertiesBuffer {
    fn new(session_name: &[u16]) -> Self {
        let mut value = Self {
            properties: EVENT_TRACE_PROPERTIES::default(),
            logger_name: [0; 128],
        };
        let copied = session_name.len().min(value.logger_name.len());
        value.logger_name[..copied].copy_from_slice(&session_name[..copied]);
        value.properties.Wnode.BufferSize = size_of::<Self>() as u32;
        value.properties.Wnode.Guid = SystemTraceControlGuid;
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

pub struct TraceSession {
    control_handle: CONTROLTRACE_HANDLE,
    session_name: Vec<u16>,
    properties: Box<TracePropertiesBuffer>,
    stats: Arc<Mutex<EventStats>>,
    consumer: JoinHandle<ConsumerResult>,
}

struct ConsumerResult {
    process_status: u32,
    events_lost: u32,
}

impl TraceSession {
    pub fn start(probe_process_id: u32) -> Result<Self, NativeFailure> {
        let session_name: Vec<u16> = format!("StorPulse.Stage0.{probe_process_id}")
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut properties = Box::new(TracePropertiesBuffer::new(&session_name));
        let mut control_handle = CONTROLTRACE_HANDLE::default();
        // SAFETY：属性缓冲区包含结构体和 logger 名称，指针在会话生命周期内保持有效。
        let start_status = unsafe {
            StartTraceW(
                &mut control_handle,
                session_name.as_ptr(),
                &mut properties.properties,
            )
        };
        if start_status != ERROR_SUCCESS {
            return Err(NativeFailure::new_with_session(
                "etw",
                "StartTraceW",
                start_status,
                false,
            ));
        }

        let stats = Arc::new(Mutex::new(EventStats::default()));
        let consumer_stats = Arc::clone(&stats);
        let consumer_name = session_name.clone();
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let consumer =
            thread::spawn(move || consume_trace(consumer_name, consumer_stats, ready_sender));

        match ready_receiver.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Self {
                control_handle,
                session_name,
                properties,
                stats,
                consumer,
            }),
            Ok(Err(code)) => {
                stop_failed_session(control_handle, &session_name, &mut properties);
                let _ = consumer.join();
                Err(NativeFailure::new_with_session(
                    "etw",
                    "OpenTraceW",
                    code,
                    true,
                ))
            }
            Err(_) => {
                stop_failed_session(control_handle, &session_name, &mut properties);
                let _ = consumer.join();
                Err(NativeFailure::new_with_session(
                    "etw",
                    "OpenTraceW.timeout",
                    1460,
                    true,
                ))
            }
        }
    }

    pub fn stop(mut self, probe_process_id: u32) -> EtwEventReport {
        // SAFETY：使用启动会话时的句柄、名称和属性缓冲区停止同一会话。
        let stop_status = unsafe {
            ControlTraceW(
                self.control_handle,
                self.session_name.as_ptr(),
                &mut self.properties.properties,
                EVENT_TRACE_CONTROL_STOP,
            )
        };
        let consumer = self.consumer.join().unwrap_or(ConsumerResult {
            process_status: 1,
            events_lost: 0,
        });
        let completion = SessionCompletion {
            stop_status,
            process_status: consumer.process_status,
            events_lost: self
                .properties
                .properties
                .EventsLost
                .max(consumer.events_lost),
            log_buffers_lost: self.properties.properties.LogBuffersLost,
            realtime_buffers_lost: self.properties.properties.RealTimeBuffersLost,
        };
        let mut stats = self
            .stats
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        stats.finish(probe_process_id, completion)
    }
}

fn stop_failed_session(
    control_handle: CONTROLTRACE_HANDLE,
    session_name: &[u16],
    properties: &mut TracePropertiesBuffer,
) {
    // SAFETY：会话刚由 StartTraceW 创建，停止时仍持有同一属性缓冲区。
    unsafe {
        ControlTraceW(
            control_handle,
            session_name.as_ptr(),
            &mut properties.properties,
            EVENT_TRACE_CONTROL_STOP,
        )
    };
}

fn consume_trace(
    mut session_name: Vec<u16>,
    stats: Arc<Mutex<EventStats>>,
    ready_sender: mpsc::SyncSender<Result<(), u32>>,
) -> ConsumerResult {
    let context = Box::new(CallbackContext { stats });
    let context_pointer = Box::into_raw(context);
    let mut logfile = EVENT_TRACE_LOGFILEW {
        LoggerName: session_name.as_mut_ptr(),
        Context: context_pointer.cast(),
        ..Default::default()
    };
    logfile.Anonymous1.ProcessTraceMode =
        PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    logfile.Anonymous2.EventRecordCallback = Some(event_record_callback);

    // SAFETY：logfile、session_name 和回调上下文在线程阻塞期间保持有效。
    let trace_handle = unsafe { OpenTraceW(&mut logfile) };
    if trace_handle.Value == INVALID_PROCESSTRACE_HANDLE {
        let code = unsafe { GetLastError() };
        let _ = ready_sender.send(Err(code));
        // SAFETY：context_pointer 来自 Box::into_raw，且尚未被回调使用。
        unsafe { drop(Box::from_raw(context_pointer)) };
        return ConsumerResult {
            process_status: code,
            events_lost: 0,
        };
    }
    let _ = ready_sender.send(Ok(()));
    // SAFETY：有效处理句柄数组，结束时间为空表示实时消费至会话停止。
    let process_status =
        unsafe { ProcessTrace(&trace_handle, 1, std::ptr::null(), std::ptr::null()) };
    // SAFETY：trace_handle 由 OpenTraceW 返回，只关闭一次。
    unsafe { CloseTrace(trace_handle) };
    // SAFETY：ProcessTrace 已返回，不再有回调访问上下文。
    unsafe { drop(Box::from_raw(context_pointer)) };
    ConsumerResult {
        process_status: if process_status == ERROR_CANCELLED {
            ERROR_SUCCESS
        } else {
            process_status
        },
        events_lost: logfile.EventsLost,
    }
}

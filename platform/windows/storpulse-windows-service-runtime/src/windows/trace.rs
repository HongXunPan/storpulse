use std::cell::Cell;
use std::sync::mpsc::{Receiver, sync_channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    ERROR_CANCELLED, ERROR_INVALID_NAME, ERROR_SUCCESS, GetLastError,
};
use windows_sys::Win32::System::Diagnostics::Etw::{
    CONTROLTRACE_HANDLE, CloseTrace, ControlTraceW, EVENT_TRACE_CONTROL_STOP, EVENT_TRACE_LOGFILEW,
    OpenTraceW, PROCESS_TRACE_MODE_EVENT_RECORD, PROCESS_TRACE_MODE_REAL_TIME, ProcessTrace,
    StartTraceW,
};

use crate::{CollectorEvent, SnapshotPublisher};

use super::trace_config::{PRODUCT_ETW_SESSION_NAME, TracePropertiesBuffer};
use super::{EtwCallbackContext, event_record_callback};

const EVENT_CHANNEL_CAPACITY: usize = 65_536;
const MAX_DRAIN_EVENTS_PER_TICK: usize = 4_096;
const INVALID_PROCESSTRACE_HANDLE: u64 = u64::MAX;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TraceError {
    pub operation: &'static str,
    pub native_code: u32,
    pub session_started: bool,
}

impl std::fmt::Display for TraceError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "ETW 操作失败：{} / {} / session_started={}",
            self.operation, self.native_code, self.session_started
        )
    }
}

impl std::error::Error for TraceError {}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TraceCompletion {
    pub stop_status: u32,
    pub process_status: u32,
    pub events_lost: u64,
    pub buffers_lost: u64,
    pub callback_events_lost: u64,
}

pub struct TraceSession {
    control_handle: CONTROLTRACE_HANDLE,
    session_name: Vec<u16>,
    properties: Box<TracePropertiesBuffer>,
    receiver: Receiver<CollectorEvent>,
    callback_context: std::sync::Arc<EtwCallbackContext>,
    callback_events_lost: Cell<u64>,
    consumer: Option<JoinHandle<ConsumerResult>>,
}

impl TraceSession {
    pub fn start() -> Result<Self, TraceError> {
        let session_name = wide(PRODUCT_ETW_SESSION_NAME);
        if session_name.len() > 128 {
            return Err(TraceError {
                operation: "session_name",
                native_code: ERROR_INVALID_NAME,
                session_started: false,
            });
        }
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
            return Err(TraceError {
                operation: "StartTraceW",
                native_code: start_status,
                session_started: false,
            });
        }

        let (sender, receiver) = sync_channel(EVENT_CHANNEL_CAPACITY);
        let callback_context = EtwCallbackContext::new(sender);
        let consumer_context = std::sync::Arc::clone(&callback_context);
        let consumer_name = session_name.clone();
        let (ready_sender, ready_receiver) = std::sync::mpsc::sync_channel(1);
        let consumer =
            thread::spawn(move || consume_trace(consumer_name, consumer_context, ready_sender));

        match ready_receiver.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Self {
                control_handle,
                session_name,
                properties,
                receiver,
                callback_context,
                callback_events_lost: Cell::new(0),
                consumer: Some(consumer),
            }),
            Ok(Err(code)) => {
                stop_failed_session(control_handle, &session_name, &mut properties);
                let _ = consumer.join();
                Err(TraceError {
                    operation: "OpenTraceW",
                    native_code: code,
                    session_started: true,
                })
            }
            Err(_) => {
                stop_failed_session(control_handle, &session_name, &mut properties);
                let _ = consumer.join();
                Err(TraceError {
                    operation: "OpenTraceW.timeout",
                    native_code: 1460,
                    session_started: true,
                })
            }
        }
    }

    pub fn drain_into(&self, publisher: &mut SnapshotPublisher) -> u64 {
        self.drain_with_loss(publisher, MAX_DRAIN_EVENTS_PER_TICK).0
    }

    fn drain_with_loss(
        &self,
        publisher: &mut SnapshotPublisher,
        maximum_events: usize,
    ) -> (u64, u64) {
        let mut drained = 0_u64;
        while drained < maximum_events as u64 {
            let Ok(event) = self.receiver.try_recv() else {
                break;
            };
            publisher.observe(event);
            drained = drained.saturating_add(1);
        }
        let callback_events_lost = match self.callback_context.take_channel_loss() {
            Some(loss @ CollectorEvent::TraceLoss { events, .. }) => {
                publisher.observe(loss);
                self.callback_events_lost
                    .set(self.callback_events_lost.get().saturating_add(events));
                events
            }
            _ => 0,
        };
        (drained, callback_events_lost)
    }

    pub fn stop(mut self, publisher: &mut SnapshotPublisher) -> TraceCompletion {
        let native = self.stop_native();
        self.drain_with_loss(publisher, usize::MAX);
        let callback_events_lost = self.callback_events_lost.get();
        let events_lost = u64::from(native.events_lost).saturating_add(callback_events_lost);
        let buffers_lost = u64::from(native.log_buffers_lost)
            .saturating_add(u64::from(native.realtime_buffers_lost));
        if events_lost > 0 || buffers_lost > 0 {
            publisher.observe(CollectorEvent::TraceLoss {
                events: u64::from(native.events_lost),
                buffers: buffers_lost,
            });
        }
        TraceCompletion {
            stop_status: native.stop_status,
            process_status: native.process_status,
            events_lost,
            buffers_lost,
            callback_events_lost,
        }
    }

    fn stop_native(&mut self) -> NativeCompletion {
        // SAFETY：使用启动时的句柄、名称和属性缓冲区停止同一会话。
        let stop_status = unsafe {
            ControlTraceW(
                self.control_handle,
                self.session_name.as_ptr(),
                &mut self.properties.properties,
                EVENT_TRACE_CONTROL_STOP,
            )
        };
        let consumer = self
            .consumer
            .take()
            .and_then(|consumer| consumer.join().ok())
            .unwrap_or(ConsumerResult {
                process_status: 1,
                events_lost: 0,
            });
        NativeCompletion {
            stop_status,
            process_status: consumer.process_status,
            events_lost: self
                .properties
                .properties
                .EventsLost
                .max(consumer.events_lost),
            log_buffers_lost: self.properties.properties.LogBuffersLost,
            realtime_buffers_lost: self.properties.properties.RealTimeBuffersLost,
        }
    }
}

impl Drop for TraceSession {
    fn drop(&mut self) {
        if self.consumer.is_some() {
            let _ = self.stop_native();
        }
    }
}

struct ConsumerResult {
    process_status: u32,
    events_lost: u32,
}

struct NativeCompletion {
    stop_status: u32,
    process_status: u32,
    events_lost: u32,
    log_buffers_lost: u32,
    realtime_buffers_lost: u32,
}

fn consume_trace(
    mut session_name: Vec<u16>,
    context: std::sync::Arc<EtwCallbackContext>,
    ready_sender: std::sync::mpsc::SyncSender<Result<(), u32>>,
) -> ConsumerResult {
    let mut logfile = EVENT_TRACE_LOGFILEW {
        LoggerName: session_name.as_mut_ptr(),
        Context: EtwCallbackContext::user_context(&context),
        ..Default::default()
    };
    logfile.Anonymous1.ProcessTraceMode =
        PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    logfile.Anonymous2.EventRecordCallback = Some(event_record_callback);

    // SAFETY：logfile、session_name 和 Arc 回调上下文在线程阻塞期间保持有效。
    let trace_handle = unsafe { OpenTraceW(&mut logfile) };
    if trace_handle.Value == INVALID_PROCESSTRACE_HANDLE {
        let code = unsafe { GetLastError() };
        let _ = ready_sender.send(Err(code));
        return ConsumerResult {
            process_status: code,
            events_lost: 0,
        };
    }
    let _ = ready_sender.send(Ok(()));
    // SAFETY：有效处理句柄数组，实时消费直到控制器停止会话。
    let process_status =
        unsafe { ProcessTrace(&trace_handle, 1, std::ptr::null(), std::ptr::null()) };
    // SAFETY：trace_handle 由 OpenTraceW 返回，只关闭一次。
    unsafe { CloseTrace(trace_handle) };
    ConsumerResult {
        process_status: if process_status == ERROR_CANCELLED {
            ERROR_SUCCESS
        } else {
            process_status
        },
        events_lost: logfile.EventsLost,
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

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

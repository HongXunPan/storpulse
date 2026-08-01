use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use storpulse_windows_service_contract::{
    ClientMessage, PROTOCOL_VERSION, SAMPLE_INTERVAL_MILLISECONDS, SNAPSHOT_SCHEMA_VERSION,
    ServiceCommandSession, ServiceMessage,
};
use windows_sys::Win32::Foundation::ERROR_SUCCESS;

use crate::SnapshotPublisher;

use super::clock::SessionClock;
use super::identity::{current_process_is_local_system, inspect_pipe_client, nonce_matches};
use super::{ProductPipe, ServiceRunError, TraceCompletion, TraceSession};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const FAILURE_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const LOOP_SLEEP: Duration = Duration::from_millis(20);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServiceOutcome {
    pub final_sequence: u64,
    pub trace: TraceCompletion,
}

pub fn run_single_session(
    expected_nonce: &str,
    stop_requested: &AtomicBool,
) -> Result<ServiceOutcome, ServiceRunError> {
    if !valid_nonce(expected_nonce) {
        return Err(ServiceRunError::authentication(None));
    }
    if !current_process_is_local_system()? {
        return Err(ServiceRunError::authentication(Some(5)));
    }
    let pipe = ProductPipe::create_server()?;
    pipe.connect_server(Instant::now() + CONNECT_TIMEOUT, stop_requested)?;
    let result = run_connected_session(&pipe, expected_nonce, stop_requested);
    if let Err(error) = result {
        send_failure(&pipe, error);
    }
    result
}

fn run_connected_session(
    pipe: &ProductPipe,
    expected_nonce: &str,
    stop_requested: &AtomicBool,
) -> Result<ServiceOutcome, ServiceRunError> {
    let mut session = ServiceCommandSession::default();
    let connect = read_client_message(pipe, stop_requested)?;
    let request = session.accept_connect(connect)?;
    let client = inspect_pipe_client(pipe.handle())?;
    if client.process_id != request.client_process_id
        || client.elevated
        || !nonce_matches(expected_nonce, &request.nonce)
    {
        session.fail_session();
        return Err(ServiceRunError::authentication(Some(5)));
    }

    session.mark_ready()?;
    write_service_message(
        pipe,
        &ServiceMessage::Ready {
            protocol_version: PROTOCOL_VERSION,
            snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
            service_process_id: std::process::id(),
            sample_interval_milliseconds: SAMPLE_INTERVAL_MILLISECONDS,
        },
        stop_requested,
    )?;

    let start = read_client_message(pipe, stop_requested)?;
    session.accept_start(&start)?;
    let trace = TraceSession::start()?;
    write_service_message(
        pipe,
        &ServiceMessage::CollectionStarted {
            protocol_version: PROTOCOL_VERSION,
            first_sequence: 1,
        },
        stop_requested,
    )?;

    let (mut publisher, trace, mut clock, last_sequence, pending_duration) =
        collect_until_stop(pipe, trace, &mut session, stop_requested)?;
    let stop_started = Instant::now();
    let completion = trace.stop(&mut publisher);
    if completion.stop_status != ERROR_SUCCESS || completion.process_status != ERROR_SUCCESS {
        let code = if completion.stop_status != ERROR_SUCCESS {
            completion.stop_status
        } else {
            completion.process_status
        };
        session.fail_session();
        return Err(ServiceRunError::shutdown(Some(code)));
    }

    let final_message = publish_snapshot(
        &mut publisher,
        &mut clock,
        pending_duration.saturating_add(stop_started.elapsed()),
    )?;
    let final_sequence = snapshot_sequence(&final_message);
    debug_assert!(final_sequence > last_sequence.unwrap_or(0));
    write_service_message(pipe, &final_message, stop_requested)?;
    session.mark_stopped()?;
    write_service_message(
        pipe,
        &ServiceMessage::Stopped {
            protocol_version: PROTOCOL_VERSION,
            final_sequence: Some(final_sequence),
        },
        stop_requested,
    )?;

    let acknowledgement = read_client_message(pipe, stop_requested)?;
    session.accept_acknowledgement(&acknowledgement)?;
    Ok(ServiceOutcome {
        final_sequence,
        trace: completion,
    })
}

fn collect_until_stop(
    pipe: &ProductPipe,
    trace: TraceSession,
    session: &mut ServiceCommandSession,
    stop_requested: &AtomicBool,
) -> Result<
    (
        SnapshotPublisher,
        TraceSession,
        SessionClock,
        Option<u64>,
        Duration,
    ),
    ServiceRunError,
> {
    let mut publisher = SnapshotPublisher::new();
    let mut clock = SessionClock::start();
    let mut next_publish = Instant::now() + Duration::from_millis(SAMPLE_INTERVAL_MILLISECONDS);
    let mut last_sequence = None;
    let mut collection_duration = Duration::ZERO;
    loop {
        if stop_requested.load(Ordering::Relaxed) {
            session.fail_session();
            return Err(ServiceRunError::shutdown(Some(995)));
        }
        let drain_started = Instant::now();
        trace.drain_into(&mut publisher);
        collection_duration = collection_duration.saturating_add(drain_started.elapsed());
        if pipe.data_available()? {
            let stop = read_client_message(pipe, stop_requested)?;
            session.accept_stop(&stop, last_sequence)?;
            return Ok((publisher, trace, clock, last_sequence, collection_duration));
        }
        if Instant::now() >= next_publish {
            let message = publish_snapshot(&mut publisher, &mut clock, collection_duration)?;
            let sequence = snapshot_sequence(&message);
            write_service_message(pipe, &message, stop_requested)?;
            last_sequence = Some(sequence);
            collection_duration = Duration::ZERO;
            next_publish = Instant::now() + Duration::from_millis(SAMPLE_INTERVAL_MILLISECONDS);
        }
        std::thread::sleep(LOOP_SLEEP);
    }
}

fn publish_snapshot(
    publisher: &mut SnapshotPublisher,
    clock: &mut SessionClock,
    collection_duration: Duration,
) -> Result<ServiceMessage, ServiceRunError> {
    let (captured_at, monotonic_nanoseconds) = clock.capture();
    let collection_duration_nanoseconds =
        collection_duration.as_nanos().min(u128::from(u64::MAX)) as u64;
    publisher
        .publish(
            captured_at,
            monotonic_nanoseconds,
            collection_duration_nanoseconds,
        )
        .map_err(Into::into)
}

fn snapshot_sequence(message: &ServiceMessage) -> u64 {
    let ServiceMessage::Snapshot { sequence, .. } = message else {
        unreachable!("发布器只生成快照消息");
    };
    *sequence
}

fn read_client_message(
    pipe: &ProductPipe,
    stop_requested: &AtomicBool,
) -> Result<ClientMessage, ServiceRunError> {
    pipe.read_message_until(Instant::now() + COMMAND_TIMEOUT, Some(stop_requested))
        .map_err(Into::into)
}

fn write_service_message(
    pipe: &ProductPipe,
    message: &ServiceMessage,
    stop_requested: &AtomicBool,
) -> Result<(), ServiceRunError> {
    pipe.write_message_until(
        message,
        Instant::now() + COMMAND_TIMEOUT,
        Some(stop_requested),
    )
    .map_err(Into::into)
}

fn send_failure(pipe: &ProductPipe, error: ServiceRunError) {
    let _ = pipe.write_message_until(
        &error.message(),
        Instant::now() + FAILURE_WRITE_TIMEOUT,
        None,
    );
}

fn valid_nonce(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

use std::time::Instant;

use storpulse_core::model::RawSnapshot;
use storpulse_windows_ipc::ProductPipe;
use storpulse_windows_service_contract::{
    ClientMessage, CollectionSession, PROTOCOL_VERSION, SNAPSHOT_SCHEMA_VERSION, ServiceMessage,
};

use super::{CONNECTION_TIMEOUT, ClientError, MESSAGE_TIMEOUT};

pub(super) struct ProductSession {
    pipe: ProductPipe,
    protocol: CollectionSession,
}

pub(super) struct DrainedCollection {
    pub(super) final_sequence: Option<u64>,
    pub(super) snapshots: Vec<(u64, RawSnapshot)>,
}

impl ProductSession {
    pub(super) fn connect(
        run_id: String,
        nonce: String,
        client_process_id: u32,
    ) -> Result<(Self, u32), ClientError> {
        let pipe = ProductPipe::connect_client(Instant::now() + CONNECTION_TIMEOUT, None)?;
        let mut protocol = CollectionSession::default();
        protocol.begin_connecting()?;
        pipe.write_message_until(
            &ClientMessage::Connect {
                protocol_version: PROTOCOL_VERSION,
                snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
                run_id,
                nonce,
                client_process_id,
            },
            Instant::now() + MESSAGE_TIMEOUT,
            None,
        )?;

        let ready = receive_message(&pipe, &mut protocol, Instant::now() + MESSAGE_TIMEOUT)?;
        let ServiceMessage::Ready {
            service_process_id, ..
        } = ready
        else {
            return Err(ClientError::protocol("expected_ready"));
        };
        Ok((Self { pipe, protocol }, service_process_id))
    }

    pub(super) fn start_collection(&mut self) -> Result<(), ClientError> {
        self.pipe.write_message_until(
            &ClientMessage::StartCollection {
                protocol_version: PROTOCOL_VERSION,
            },
            Instant::now() + MESSAGE_TIMEOUT,
            None,
        )?;
        let started = self.receive_message(Instant::now() + MESSAGE_TIMEOUT)?;
        if !matches!(started, ServiceMessage::CollectionStarted { .. }) {
            return Err(ClientError::protocol("expected_collection_started"));
        }
        Ok(())
    }

    pub(super) fn receive_snapshot(
        &mut self,
        deadline: Instant,
    ) -> Result<(u64, RawSnapshot), ClientError> {
        let message = self.receive_message(deadline)?;
        let ServiceMessage::Snapshot {
            sequence, snapshot, ..
        } = message
        else {
            return Err(ClientError::protocol("expected_snapshot"));
        };
        Ok((sequence, *snapshot))
    }

    pub(super) fn stop_collection(&mut self) -> Result<DrainedCollection, ClientError> {
        self.protocol.request_stop()?;
        self.pipe.write_message_until(
            &ClientMessage::StopCollection {
                protocol_version: PROTOCOL_VERSION,
                last_sequence: self.protocol.last_sequence(),
            },
            Instant::now() + MESSAGE_TIMEOUT,
            None,
        )?;

        let mut snapshots = Vec::new();
        let final_sequence = loop {
            match self.receive_message(Instant::now() + MESSAGE_TIMEOUT)? {
                ServiceMessage::Snapshot {
                    sequence, snapshot, ..
                } => snapshots.push((sequence, *snapshot)),
                ServiceMessage::Stopped { final_sequence, .. } => break final_sequence,
                _ => return Err(ClientError::protocol("expected_draining_message")),
            }
        };

        self.pipe.write_message_until(
            &ClientMessage::AcknowledgeStop {
                protocol_version: PROTOCOL_VERSION,
            },
            Instant::now() + MESSAGE_TIMEOUT,
            None,
        )?;
        Ok(DrainedCollection {
            final_sequence,
            snapshots,
        })
    }

    fn receive_message(&mut self, deadline: Instant) -> Result<ServiceMessage, ClientError> {
        receive_message(&self.pipe, &mut self.protocol, deadline)
    }
}

fn receive_message(
    pipe: &ProductPipe,
    protocol: &mut CollectionSession,
    deadline: Instant,
) -> Result<ServiceMessage, ClientError> {
    let message: ServiceMessage = pipe.read_message_until(deadline, None)?;
    if let ServiceMessage::Failed {
        phase,
        safe_error_code,
        native_code,
        ..
    } = &message
    {
        protocol.fail();
        return Err(ClientError::remote(*phase, *safe_error_code, *native_code));
    }
    protocol.observe(&message)?;
    Ok(message)
}

use storpulse_windows_service_contract::{
    ClientMessage, CollectionState, PROTOCOL_VERSION, SNAPSHOT_SCHEMA_VERSION,
    ServiceCommandSession, ServiceSessionError,
};

#[test]
fn accepts_complete_service_command_flow() {
    let mut session = ServiceCommandSession::default();
    let request = session.accept_connect(connect()).unwrap();
    assert_eq!(request.client_process_id, 42);
    session.mark_ready().unwrap();
    session.accept_start(&start()).unwrap();
    session.accept_stop(&stop(Some(2)), Some(2)).unwrap();
    session.mark_stopped().unwrap();
    session.accept_acknowledgement(&acknowledge()).unwrap();

    assert_eq!(session.state(), CollectionState::Stopped);
}

#[test]
fn rejects_unsafe_connect_fields_and_enters_failed_state() {
    let mut session = ServiceCommandSession::default();
    let ClientMessage::Connect {
        protocol_version,
        snapshot_schema_version,
        nonce,
        client_process_id,
        ..
    } = connect()
    else {
        unreachable!();
    };
    let error = session
        .accept_connect(ClientMessage::Connect {
            protocol_version,
            snapshot_schema_version,
            run_id: "../../machine-path".to_owned(),
            nonce,
            client_process_id,
        })
        .unwrap_err();

    assert_eq!(error, ServiceSessionError::InvalidRunId);
    assert_eq!(session.state(), CollectionState::Failed);
}

#[test]
fn accepts_lagging_stop_sequence_but_rejects_future_sequence() {
    let mut session = collecting_session();
    session.accept_stop(&stop(Some(1)), Some(2)).unwrap();
    assert_eq!(session.state(), CollectionState::Draining);

    let mut future = collecting_session();
    let error = future.accept_stop(&stop(Some(3)), Some(2)).unwrap_err();

    assert_eq!(
        error,
        ServiceSessionError::StopSequenceMismatch {
            expected: Some(2),
            received: Some(3),
        }
    );
    assert_eq!(future.state(), CollectionState::Failed);
}

#[test]
fn rejects_out_of_order_command() {
    let mut session = ServiceCommandSession::default();
    let error = session.accept_start(&start()).unwrap_err();

    assert!(matches!(
        error,
        ServiceSessionError::InvalidTransition {
            state: CollectionState::Disconnected,
            message: "start_collection",
        }
    ));
}

fn collecting_session() -> ServiceCommandSession {
    let mut session = ServiceCommandSession::default();
    session.accept_connect(connect()).unwrap();
    session.mark_ready().unwrap();
    session.accept_start(&start()).unwrap();
    session
}

fn connect() -> ClientMessage {
    ClientMessage::Connect {
        protocol_version: PROTOCOL_VERSION,
        snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
        run_id: "run-20260801-001".to_owned(),
        nonce: "ab".repeat(32),
        client_process_id: 42,
    }
}

fn start() -> ClientMessage {
    ClientMessage::StartCollection {
        protocol_version: PROTOCOL_VERSION,
    }
}

fn stop(last_sequence: Option<u64>) -> ClientMessage {
    ClientMessage::StopCollection {
        protocol_version: PROTOCOL_VERSION,
        last_sequence,
    }
}

fn acknowledge() -> ClientMessage {
    ClientMessage::AcknowledgeStop {
        protocol_version: PROTOCOL_VERSION,
    }
}

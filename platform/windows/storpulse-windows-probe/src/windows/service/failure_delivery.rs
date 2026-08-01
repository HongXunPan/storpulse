use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use super::ServiceFailure;
use super::protocol::{SCHEMA_VERSION, ServiceRequest, ServiceResponse};
use super::transport::Pipe;

pub(super) fn send_failure(pipe: &Pipe, error: &ServiceFailure, stop_requested: &AtomicBool) {
    if pipe
        .write_message(&ServiceResponse::Failed {
            schema_version: SCHEMA_VERSION,
            phase: error.phase.to_string(),
            api: error.api.to_string(),
            code: error.code,
        })
        .is_err()
    {
        return;
    }
    let acknowledgement = pipe
        .read_payload_until(
            Instant::now() + Duration::from_secs(5),
            Some(stop_requested),
        )
        .and_then(|payload| ServiceRequest::decode(&payload));
    let _acknowledged = matches!(
        acknowledgement,
        Ok(ServiceRequest::Acknowledge {
            schema_version: SCHEMA_VERSION
        })
    );
}

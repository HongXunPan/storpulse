use std::time::Instant;

use serde::Serialize;
use storpulse_core::model::RawSnapshot;

use crate::SafeFailure;

use super::super::product_session::{DrainedCollection, ProductSession};
use super::super::{ClientError, SHUTDOWN_TIMEOUT, auth, identity, scm};

pub(super) struct SessionState {
    product: Option<ProductSession>,
    service_started: bool,
    last_error: Option<SafeFailure>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct StopResult {
    schema_version: u32,
    final_sequence: Option<u64>,
    final_snapshots: Vec<RawSnapshot>,
    service_stopped: bool,
    service_win32_exit_code: u32,
    service_specific_exit_code: u32,
}

impl SessionState {
    pub(super) fn new() -> Self {
        Self {
            product: None,
            service_started: false,
            last_error: None,
        }
    }

    pub(super) fn is_started(&self) -> bool {
        self.product.is_some() || self.service_started
    }

    pub(super) fn has_product(&self) -> bool {
        self.product.is_some()
    }

    pub(super) fn product_mut(&mut self) -> Option<&mut ProductSession> {
        self.product.as_mut()
    }

    pub(super) fn last_error(&self) -> Option<&SafeFailure> {
        self.last_error.as_ref()
    }

    pub(super) fn record_error(&mut self, failure: SafeFailure) {
        self.last_error = Some(failure);
    }

    pub(super) fn clear_error(&mut self) {
        self.last_error = None;
    }

    pub(super) fn start(&mut self, run_id: String) -> Result<(), ClientError> {
        if identity::current_process_elevated()? {
            return Err(ClientError::new(
                "environment",
                "standard_user_required",
                Some(5),
            ));
        }

        let nonce = auth::generate_nonce()?;
        scm::start(&nonce)?;
        self.service_started = true;

        let connected = ProductSession::connect(run_id, nonce, std::process::id());
        let (mut product, _service_process_id) = match connected {
            Ok(value) => value,
            Err(error) => {
                self.wait_for_service_after_failure();
                return Err(error);
            }
        };
        if let Err(error) = product.start_collection() {
            drop(product);
            self.wait_for_service_after_failure();
            return Err(error);
        }
        self.product = Some(product);
        Ok(())
    }

    pub(super) fn stop(&mut self) -> Result<StopResult, ClientError> {
        let mut product = self
            .product
            .take()
            .ok_or_else(|| ClientError::new("lifecycle", "session_not_started", None))?;
        let drained = product.stop_collection();
        drop(product);
        let service_status = self.wait_for_service();

        let DrainedCollection {
            final_sequence,
            snapshots,
        } = drained?;
        let service_status = service_status?;
        if !service_status.stopped {
            return Err(ClientError::new(
                "shutdown",
                "service_stop_timeout",
                Some(1460),
            ));
        }
        if service_status.win32_exit_code != 0 || service_status.service_specific_exit_code != 0 {
            let native_code = if service_status.service_specific_exit_code != 0 {
                service_status.service_specific_exit_code
            } else {
                service_status.win32_exit_code
            };
            return Err(ClientError::new(
                "shutdown",
                "service_exit_failed",
                Some(native_code),
            ));
        }

        Ok(StopResult {
            schema_version: 1,
            final_sequence,
            final_snapshots: snapshots
                .into_iter()
                .map(|(_sequence, snapshot)| snapshot)
                .collect(),
            service_stopped: true,
            service_win32_exit_code: service_status.win32_exit_code,
            service_specific_exit_code: service_status.service_specific_exit_code,
        })
    }

    fn wait_for_service(&mut self) -> Result<scm::ServiceStopStatus, ClientError> {
        let result = scm::wait_until_stopped(Instant::now() + SHUTDOWN_TIMEOUT);
        if result.as_ref().is_ok_and(|status| status.stopped) {
            self.service_started = false;
        }
        result
    }

    fn wait_for_service_after_failure(&mut self) {
        let _ = self.wait_for_service();
    }
}

impl Drop for SessionState {
    fn drop(&mut self) {
        if let Some(mut product) = self.product.take() {
            let _ = product.stop_collection();
            drop(product);
        }
        if self.service_started {
            self.wait_for_service_after_failure();
        }
    }
}

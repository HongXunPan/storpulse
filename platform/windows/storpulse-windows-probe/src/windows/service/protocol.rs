use serde::{Deserialize, Serialize};

use crate::model::{EtwEventReport, ServiceGateReport};

use super::super::process::ProcessIdentity;

pub(super) const SCHEMA_VERSION: u32 = 1;

#[derive(Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub(super) enum ServiceRequest {
    Begin {
        schema_version: u32,
        nonce: String,
        client_process_id: u32,
        duration_seconds: u64,
    },
    Finish {
        schema_version: u32,
        short_lived_processes: Vec<ProcessIdentity>,
    },
    Acknowledge {
        schema_version: u32,
    },
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub(super) enum ServiceResponse {
    Ready {
        schema_version: u32,
        service_process_id: u32,
        service_local_system: bool,
        client_process_id_matched: bool,
        client_elevated: Option<bool>,
    },
    Completed {
        schema_version: u32,
        etw: Box<EtwEventReport>,
        service: ServiceGateReport,
    },
    Failed {
        schema_version: u32,
        phase: String,
        api: String,
        code: u32,
    },
}

impl ServiceRequest {
    pub(super) fn schema_version(&self) -> u32 {
        match self {
            Self::Begin { schema_version, .. }
            | Self::Finish { schema_version, .. }
            | Self::Acknowledge { schema_version } => *schema_version,
        }
    }
}

impl ServiceResponse {
    pub(super) fn schema_version(&self) -> u32 {
        match self {
            Self::Ready { schema_version, .. }
            | Self::Completed { schema_version, .. }
            | Self::Failed { schema_version, .. } => *schema_version,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn begin_request_has_stable_tag_and_version() {
        let request = ServiceRequest::Begin {
            schema_version: SCHEMA_VERSION,
            nonce: "00".repeat(32),
            client_process_id: 42,
            duration_seconds: 15,
        };
        let encoded = serde_json::to_string(&request).expect("协议应可编码");
        let decoded: ServiceRequest = serde_json::from_str(&encoded).expect("协议应可解码");

        assert!(encoded.contains("\"command\":\"begin\""));
        assert_eq!(decoded.schema_version(), SCHEMA_VERSION);
    }

    #[test]
    fn acknowledgement_has_stable_tag_and_version() {
        let request = ServiceRequest::Acknowledge {
            schema_version: SCHEMA_VERSION,
        };
        let encoded = serde_json::to_string(&request).expect("协议应可编码");
        let decoded: ServiceRequest = serde_json::from_str(&encoded).expect("协议应可解码");

        assert!(encoded.contains("\"command\":\"acknowledge\""));
        assert_eq!(decoded.schema_version(), SCHEMA_VERSION);
    }
}

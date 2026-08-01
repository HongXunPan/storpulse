use serde::{Deserialize, Serialize};

use crate::model::{EtwEventReport, ServiceGateReport};

use super::super::process::ProcessIdentity;
use super::ServiceFailure;

mod response_decoder;

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

#[derive(Serialize)]
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
    pub(super) fn decode(payload: &[u8]) -> Result<Self, ServiceFailure> {
        serde_json::from_slice(payload)
            .map_err(|error| ServiceFailure::new("ipc", request_decode_error_api(&error), 13))
    }

    pub(super) fn schema_version(&self) -> u32 {
        match self {
            Self::Begin { schema_version, .. }
            | Self::Finish { schema_version, .. }
            | Self::Acknowledge { schema_version } => *schema_version,
        }
    }
}

impl ServiceResponse {
    pub(super) fn decode(payload: &[u8]) -> Result<Self, ServiceFailure> {
        response_decoder::decode(payload)
    }

    pub(super) fn validate_round_trip(&self) -> Result<(), ServiceFailure> {
        let payload = serde_json::to_vec(self)
            .map_err(|_| ServiceFailure::new("ipc", "serde_json.serialize.response", 13))?;
        Self::decode(&payload).map(|_| ())
    }

    pub(super) fn schema_version(&self) -> u32 {
        match self {
            Self::Ready { schema_version, .. }
            | Self::Completed { schema_version, .. }
            | Self::Failed { schema_version, .. } => *schema_version,
        }
    }
}

fn request_decode_error_api(error: &serde_json::Error) -> &'static str {
    if error.to_string().starts_with("trailing characters") {
        return "serde_json.deserialize.request.trailing";
    }
    match error.classify() {
        serde_json::error::Category::Io => "serde_json.deserialize.request.io",
        serde_json::error::Category::Syntax => "serde_json.deserialize.request.syntax",
        serde_json::error::Category::Data => "serde_json.deserialize.request.data",
        serde_json::error::Category::Eof => "serde_json.deserialize.request.eof",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ProcessDiskIoReport;

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

    #[test]
    fn completed_response_round_trips_with_large_etw_report() {
        let mut etw = EtwEventReport::default();
        etw.events_by_opcode.insert(10, 512);
        etw.events_by_opcode.insert(11, 256);
        etw.top_processes = (0..256)
            .map(|process_id| ProcessDiskIoReport {
                process_id,
                is_probe: process_id == 42,
                read_bytes: u64::from(process_id) * 1_024,
                write_bytes: u64::from(process_id) * 2_048,
                read_events: u64::from(process_id) * 3,
                write_events: u64::from(process_id) * 5,
            })
            .collect();
        let mut service = ServiceGateReport::default();
        service.service_name = "StorPulseStage0Collector".to_string();
        service.service_process_id = 4_242;
        service.service_local_system = true;
        service.client_process_id_matched = true;
        service.client_elevated = Some(false);
        service.client_authenticated = true;
        service.pipe_reject_remote_clients = true;
        service.service_self_measurements.working_set_bytes = 4 * 1_024 * 1_024;
        let response = ServiceResponse::Completed {
            schema_version: SCHEMA_VERSION,
            etw: Box::new(etw),
            service,
        };

        let encoded = serde_json::to_vec(&response).expect("大型完成响应应可编码");
        assert!(encoded.len() > 16 * 1_024);
        assert!(encoded.len() < 65_536);
        if let Err(failure) = response.validate_round_trip() {
            panic!("真实字段组合应可往返：{}", failure.api);
        }

        let decoded = match ServiceResponse::decode(&encoded) {
            Ok(response) => response,
            Err(failure) => panic!("大型完成响应应可解码：{}", failure.api),
        };
        match decoded {
            ServiceResponse::Completed { etw, .. } => {
                assert_eq!(etw.top_processes.len(), 256);
                assert_eq!(etw.events_by_opcode.get(&10), Some(&512));
            }
            _ => panic!("响应类型应保持 completed"),
        }
    }

    #[test]
    fn response_decode_identifies_missing_status() {
        let failure = ServiceResponse::decode(br#"{"command":"finish"}"#)
            .err()
            .expect("缺少响应状态应失败");

        assert_eq!(
            failure.api,
            "serde_json.deserialize.response.missing_status"
        );
    }

    #[test]
    fn response_decode_identifies_invalid_opcode_map() {
        let response = ServiceResponse::Completed {
            schema_version: SCHEMA_VERSION,
            etw: Box::new(EtwEventReport::default()),
            service: ServiceGateReport::default(),
        };
        let mut value = serde_json::to_value(response).expect("响应应可转为 JSON 值");
        value["etw"]["eventsByOpcode"] = serde_json::json!({ "invalid": 1 });
        let payload = serde_json::to_vec(&value).expect("诊断负载应可编码");
        let failure = ServiceResponse::decode(&payload)
            .err()
            .expect("非法 opcode 映射应失败");

        assert_eq!(
            failure.api,
            "serde_json.deserialize.response.completed.etw.events_by_opcode"
        );
    }

    #[test]
    fn response_decode_constructs_each_small_response_variant() {
        let ready = br#"{"status":"ready","schema_version":1,"service_process_id":42,"service_local_system":true,"client_process_id_matched":true,"client_elevated":false}"#;
        let failed =
            br#"{"status":"failed","schema_version":1,"phase":"etw","api":"StartTraceW","code":5}"#;

        assert!(matches!(
            ServiceResponse::decode(ready),
            Ok(ServiceResponse::Ready {
                service_process_id: 42,
                ..
            })
        ));
        assert!(matches!(
            ServiceResponse::decode(failed),
            Ok(ServiceResponse::Failed { code: 5, .. })
        ));
    }
}

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

use crate::model::{EtwEventReport, ProcessDiskIoReport, SelfMeasurementReport, ServiceGateReport};

use super::ServiceResponse;
use crate::windows::service::ServiceFailure;

#[derive(Deserialize)]
struct ReadyPayload {
    schema_version: u32,
    service_process_id: u32,
    service_local_system: bool,
    client_process_id_matched: bool,
    client_elevated: Option<bool>,
}

#[derive(Deserialize)]
struct CompletedPayload {
    schema_version: u32,
    etw: Box<EtwEventReport>,
    service: ServiceGateReport,
}

#[derive(Deserialize)]
struct FailedPayload {
    schema_version: u32,
    phase: String,
    api: String,
    code: u32,
}

pub(super) fn decode(payload: &[u8]) -> Result<ServiceResponse, ServiceFailure> {
    let value = serde_json::from_slice::<Value>(payload)
        .map_err(|error| ServiceFailure::new("ipc", response_parse_error_api(&error), 13))?;
    let Some(response) = value.as_object() else {
        return Err(decode_failure("serde_json.deserialize.response.root"));
    };
    let Some(status) = response
        .get("status")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        return Err(decode_failure(
            "serde_json.deserialize.response.missing_status",
        ));
    };

    match status.as_str() {
        "ready" => decode_ready(value),
        "completed" => decode_completed(value),
        "failed" => decode_failed(value),
        _ => Err(decode_failure(
            "serde_json.deserialize.response.unknown_status",
        )),
    }
}

fn decode_ready(value: Value) -> Result<ServiceResponse, ServiceFailure> {
    let payload = serde_json::from_value::<ReadyPayload>(value)
        .map_err(|_| decode_failure("serde_json.deserialize.response.ready"))?;
    Ok(ServiceResponse::Ready {
        schema_version: payload.schema_version,
        service_process_id: payload.service_process_id,
        service_local_system: payload.service_local_system,
        client_process_id_matched: payload.client_process_id_matched,
        client_elevated: payload.client_elevated,
    })
}

fn decode_completed(value: Value) -> Result<ServiceResponse, ServiceFailure> {
    let response = value.as_object().expect("根对象已经在分派响应前验证");
    let payload = serde_json::from_value::<CompletedPayload>(value.clone())
        .map_err(|_| decode_failure(diagnose_completed_response(response)))?;
    Ok(ServiceResponse::Completed {
        schema_version: payload.schema_version,
        etw: payload.etw,
        service: payload.service,
    })
}

fn decode_failed(value: Value) -> Result<ServiceResponse, ServiceFailure> {
    let payload = serde_json::from_value::<FailedPayload>(value)
        .map_err(|_| decode_failure("serde_json.deserialize.response.failed"))?;
    Ok(ServiceResponse::Failed {
        schema_version: payload.schema_version,
        phase: payload.phase,
        api: payload.api,
        code: payload.code,
    })
}

fn decode_failure(api: &'static str) -> ServiceFailure {
    ServiceFailure::new("ipc", api, 13)
}

fn response_parse_error_api(error: &serde_json::Error) -> &'static str {
    if error.to_string().starts_with("trailing characters") {
        return "serde_json.deserialize.response.trailing";
    }
    match error.classify() {
        serde_json::error::Category::Io => "serde_json.deserialize.response.io",
        serde_json::error::Category::Syntax => "serde_json.deserialize.response.syntax",
        serde_json::error::Category::Data => "serde_json.deserialize.response.data",
        serde_json::error::Category::Eof => "serde_json.deserialize.response.eof",
    }
}

fn diagnose_completed_response(response: &serde_json::Map<String, Value>) -> &'static str {
    let Some(etw) = response.get("etw") else {
        return "serde_json.deserialize.response.completed.missing_etw";
    };
    if serde_json::from_value::<EtwEventReport>(etw.clone()).is_err() {
        return diagnose_etw_report(etw);
    }
    let Some(service) = response.get("service") else {
        return "serde_json.deserialize.response.completed.missing_service";
    };
    if serde_json::from_value::<ServiceGateReport>(service.clone()).is_err() {
        return diagnose_service_report(service);
    }
    "serde_json.deserialize.response.completed.wrapper"
}

fn diagnose_etw_report(etw: &Value) -> &'static str {
    let Some(report) = etw.as_object() else {
        return "serde_json.deserialize.response.completed.etw_shape";
    };
    let opcode_valid = report
        .get("eventsByOpcode")
        .is_some_and(|value| serde_json::from_value::<BTreeMap<u8, u64>>(value.clone()).is_ok());
    if !opcode_valid {
        return "serde_json.deserialize.response.completed.etw.events_by_opcode";
    }
    let processes_valid = report.get("topProcesses").is_some_and(|value| {
        serde_json::from_value::<Vec<ProcessDiskIoReport>>(value.clone()).is_ok()
    });
    if !processes_valid {
        return "serde_json.deserialize.response.completed.etw.top_processes";
    }
    "serde_json.deserialize.response.completed.etw.scalar"
}

fn diagnose_service_report(service: &Value) -> &'static str {
    let Some(report) = service.as_object() else {
        return "serde_json.deserialize.response.completed.service_shape";
    };
    let measurements_valid = report.get("serviceSelfMeasurements").is_some_and(|value| {
        serde_json::from_value::<SelfMeasurementReport>(value.clone()).is_ok()
    });
    if !measurements_valid {
        return "serde_json.deserialize.response.completed.service.self_measurements";
    }
    "serde_json.deserialize.response.completed.service.scalar"
}

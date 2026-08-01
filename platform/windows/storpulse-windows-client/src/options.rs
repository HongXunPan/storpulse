use std::ffi::OsString;
use std::path::PathBuf;

use storpulse_windows_client::{GateMode, GateOptions};

pub(crate) fn parse(arguments: Vec<OsString>) -> Result<GateOptions, &'static str> {
    let mut arguments = arguments.into_iter();
    let mut output_directory = None;
    let mut run_id = None;
    let mut duration_seconds = 8_u64;
    let mut mode = GateMode::ContinuousValidation;
    let mut mode_selected = false;

    while let Some(argument) = arguments.next() {
        match argument.to_string_lossy().as_ref() {
            "--output" => output_directory = arguments.next().map(PathBuf::from),
            "--run-id" => {
                run_id = arguments
                    .next()
                    .map(|value| value.to_string_lossy().into_owned())
            }
            "--duration-seconds" => {
                let value = arguments.next().ok_or("missing_duration")?;
                duration_seconds = value
                    .to_string_lossy()
                    .parse::<u64>()
                    .map_err(|_| "invalid_duration")?;
            }
            "--disconnect-after-ready" => {
                select_mode(&mut mode, &mut mode_selected, GateMode::DisconnectCleanup)?
            }
            "--connect-timeout-validation" => select_mode(
                &mut mode,
                &mut mode_selected,
                GateMode::ConnectTimeoutCleanup,
            )?,
            "--terminate-after-collection-started" => select_mode(
                &mut mode,
                &mut mode_selected,
                GateMode::ClientTerminationCleanup,
            )?,
            _ => return Err("unknown_argument"),
        }
    }

    let output_directory = output_directory.ok_or("missing_output")?;
    let run_id = run_id.ok_or("missing_run_id")?;
    if !(5..=60).contains(&duration_seconds) {
        return Err("invalid_duration");
    }
    if !valid_run_id(&run_id) {
        return Err("invalid_run_id");
    }
    Ok(GateOptions {
        output_directory,
        run_id,
        duration_seconds,
        mode,
    })
}

fn select_mode(
    mode: &mut GateMode,
    selected: &mut bool,
    candidate: GateMode,
) -> Result<(), &'static str> {
    if *selected {
        return Err("conflicting_gate_mode");
    }
    *mode = candidate;
    *selected = true;
    Ok(())
}

fn valid_run_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_safe_gate_arguments() {
        let options = parse(vec![
            "--output".into(),
            "reports".into(),
            "--run-id".into(),
            "run-20260801-001".into(),
            "--duration-seconds".into(),
            "15".into(),
            "--disconnect-after-ready".into(),
        ])
        .unwrap();

        assert_eq!(options.duration_seconds, 15);
        assert_eq!(options.mode, GateMode::DisconnectCleanup);
    }

    #[test]
    fn rejects_path_like_run_id_and_unbounded_duration() {
        let invalid_run_id = parse(vec![
            "--output".into(),
            "reports".into(),
            "--run-id".into(),
            "../../machine".into(),
        ]);
        assert_eq!(invalid_run_id.unwrap_err(), "invalid_run_id");

        let invalid_duration = parse(vec![
            "--output".into(),
            "reports".into(),
            "--run-id".into(),
            "run-1".into(),
            "--duration-seconds".into(),
            "300".into(),
        ]);
        assert_eq!(invalid_duration.unwrap_err(), "invalid_duration");
    }

    #[test]
    fn parses_timeout_and_termination_modes_but_rejects_conflicts() {
        let timeout = parse(vec![
            "--output".into(),
            "reports".into(),
            "--run-id".into(),
            "run-timeout".into(),
            "--connect-timeout-validation".into(),
        ])
        .unwrap();
        assert_eq!(timeout.mode, GateMode::ConnectTimeoutCleanup);

        let termination = parse(vec![
            "--output".into(),
            "reports".into(),
            "--run-id".into(),
            "run-termination".into(),
            "--terminate-after-collection-started".into(),
        ])
        .unwrap();
        assert_eq!(termination.mode, GateMode::ClientTerminationCleanup);

        let conflicting = parse(vec![
            "--output".into(),
            "reports".into(),
            "--run-id".into(),
            "run-conflict".into(),
            "--disconnect-after-ready".into(),
            "--connect-timeout-validation".into(),
        ]);
        assert_eq!(conflicting.unwrap_err(), "conflicting_gate_mode");
    }
}

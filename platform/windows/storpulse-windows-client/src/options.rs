use std::ffi::OsString;
use std::path::PathBuf;

use storpulse_windows_client::GateOptions;

pub(crate) fn parse(arguments: Vec<OsString>) -> Result<GateOptions, &'static str> {
    let mut arguments = arguments.into_iter();
    let mut output_directory = None;
    let mut run_id = None;
    let mut duration_seconds = 8_u64;
    let mut disconnect_after_ready = false;

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
            "--disconnect-after-ready" => disconnect_after_ready = true,
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
        disconnect_after_ready,
    })
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
        assert!(options.disconnect_after_ready);
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
}

use std::path::PathBuf;

pub struct ProbeOptions {
    pub output_directory: PathBuf,
    pub duration_seconds: u64,
    pub skip_workload: bool,
}

impl ProbeOptions {
    pub fn parse() -> Result<Self, String> {
        let mut arguments = std::env::args_os().skip(1);
        let mut output_directory = None;
        let mut duration_seconds = 15;
        let mut skip_workload = false;

        while let Some(argument) = arguments.next() {
            match argument.to_string_lossy().as_ref() {
                "--output" => {
                    output_directory = arguments.next().map(PathBuf::from);
                }
                "--duration-seconds" => {
                    let value = arguments
                        .next()
                        .ok_or_else(|| "缺少 --duration-seconds 参数值".to_string())?;
                    duration_seconds = value
                        .to_string_lossy()
                        .parse::<u64>()
                        .map_err(|_| "--duration-seconds 必须是整数".to_string())?;
                }
                "--skip-workload" => skip_workload = true,
                "--help" | "-h" => {
                    return Err(
                        "用法：storpulse-windows-probe --output <目录> [--duration-seconds 15] [--skip-workload]"
                            .to_string(),
                    );
                }
                _ => return Err("存在无法识别的参数".to_string()),
            }
        }

        let output_directory =
            output_directory.ok_or_else(|| "必须指定 --output 目录".to_string())?;
        if !(5..=300).contains(&duration_seconds) {
            return Err("--duration-seconds 必须介于 5 到 300 秒".to_string());
        }

        Ok(Self {
            output_directory,
            duration_seconds,
            skip_workload,
        })
    }
}

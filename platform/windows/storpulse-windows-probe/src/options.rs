use std::ffi::OsString;
use std::path::PathBuf;

pub const SHORT_LIVED_READ_PATH_ENV: &str = "STORPULSE_STAGE0_SHORT_READ_PATH";

pub enum ProbeCommand {
    Diagnostic(ProbeOptions),
    ShortLivedRead(PathBuf),
}

pub struct ProbeOptions {
    pub output_directory: PathBuf,
    pub duration_seconds: u64,
    pub skip_workload: bool,
}

impl ProbeOptions {
    fn parse(arguments: Vec<OsString>) -> Result<Self, String> {
        let mut arguments = arguments.into_iter();
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

impl ProbeCommand {
    pub fn parse() -> Result<Self, String> {
        let arguments: Vec<_> = std::env::args_os().skip(1).collect();
        if arguments.len() == 1 && arguments[0].to_string_lossy() == "--short-lived-read" {
            let path = std::env::var_os(SHORT_LIVED_READ_PATH_ENV)
                .map(PathBuf::from)
                .ok_or_else(|| "短命读取模式缺少内部路径".to_string())?;
            return Ok(Self::ShortLivedRead(path));
        }
        ProbeOptions::parse(arguments).map(Self::Diagnostic)
    }
}

#[cfg(any(windows, test))]
mod options;

fn main() -> std::process::ExitCode {
    #[cfg(windows)]
    {
        run_windows()
    }

    #[cfg(not(windows))]
    {
        eprintln!("StorPulse Windows 客户端只能在 Windows x64 环境运行。");
        std::process::ExitCode::from(78)
    }
}

#[cfg(windows)]
fn run_windows() -> std::process::ExitCode {
    let options = match options::parse(std::env::args_os().skip(1).collect()) {
        Ok(options) => options,
        Err(code) => {
            eprintln!("Windows 持续采集参数无效：{code}");
            return std::process::ExitCode::from(64);
        }
    };
    let report = storpulse_windows_client::run_gate(&options);
    if write_report(&options.output_directory, &report).is_err() {
        eprintln!("Windows 持续采集报告写入失败。");
        return std::process::ExitCode::FAILURE;
    }
    println!("Windows 持续采集结果：{}", report.outcome);
    if report.succeeded() {
        std::process::ExitCode::SUCCESS
    } else {
        std::process::ExitCode::FAILURE
    }
}

#[cfg(windows)]
fn write_report(
    output_directory: &std::path::Path,
    report: &storpulse_windows_client::GateReport,
) -> Result<(), ()> {
    std::fs::create_dir_all(output_directory).map_err(|_| ())?;
    let temporary = output_directory.join(".summary.json.writing");
    let destination = output_directory.join("summary.json");
    let bytes = serde_json::to_vec_pretty(report).map_err(|_| ())?;
    std::fs::write(&temporary, bytes).map_err(|_| ())?;
    std::fs::rename(temporary, destination).map_err(|_| ())
}

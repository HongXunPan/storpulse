#[cfg(any(windows, test))]
mod start_argument;

#[cfg(windows)]
mod windows;

fn main() -> std::process::ExitCode {
    #[cfg(windows)]
    {
        match windows::run_dispatcher() {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(_) => std::process::ExitCode::FAILURE,
        }
    }

    #[cfg(not(windows))]
    {
        eprintln!("StorPulse Windows 服务只能由 Windows 服务控制管理器启动。");
        std::process::ExitCode::from(78)
    }
}

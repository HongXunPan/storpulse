#[cfg(windows)]
mod model;
#[cfg(windows)]
mod options;
#[cfg(windows)]
mod report;

#[cfg(windows)]
mod windows;

fn main() {
    #[cfg(windows)]
    {
        if let Err(error) = windows::run() {
            eprintln!("Windows 阶段 0 探针失败：{}", error.safe_message());
            std::process::exit(1);
        }
    }

    #[cfg(not(windows))]
    {
        eprintln!("Windows 阶段 0 探针只能在 Windows x64 环境运行。");
        std::process::exit(78);
    }
}

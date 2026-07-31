use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};

use windows_sys::Win32::Foundation::ERROR_INVALID_DATA;

use crate::model::WorkloadReport;
use crate::options::SHORT_LIVED_READ_PATH_ENV;

use super::process::ProcessIdentity;
use super::{NativeFailure, process, unbuffered_file};

const SEQUENTIAL_MEBIBYTES: u32 = 64;
const SMALL_FILE_COUNT: u32 = 500;
const SHORT_LIVED_PROCESS_COUNT: u32 = 40;
const SHORT_LIVED_READ_BYTES: u64 = 1_048_576;

pub(super) struct WorkloadOutcome {
    pub(super) report: WorkloadReport,
    pub(super) short_lived_processes: Vec<ProcessIdentity>,
    pub(super) short_lived_process_handles: Vec<Child>,
}

pub(super) fn perform(
    output_directory: &Path,
    skip: bool,
) -> Result<WorkloadOutcome, NativeFailure> {
    if skip {
        return Ok(WorkloadOutcome {
            report: WorkloadReport::default(),
            short_lived_processes: Vec::new(),
            short_lived_process_handles: Vec::new(),
        });
    }

    let workload_directory = output_directory.join("workload-active");
    let _ = fs::remove_dir_all(&workload_directory);
    fs::create_dir_all(&workload_directory)
        .map_err(|error| io_failure("workload", "create_directory", error))?;

    let result = perform_inner(&workload_directory);
    let cleanup_succeeded = fs::remove_dir_all(&workload_directory).is_ok();
    result.map(|mut outcome| {
        outcome.report.cleanup_succeeded = cleanup_succeeded;
        outcome
    })
}

pub(super) fn perform_short_lived_read(path: &Path) -> Result<(), NativeFailure> {
    let report = unbuffered_file::read_prefix(path, SHORT_LIVED_READ_BYTES)?;
    if report.bytes != SHORT_LIVED_READ_BYTES {
        return Err(NativeFailure::new(
            "workload",
            "short_lived_read_length",
            ERROR_INVALID_DATA,
        ));
    }
    Ok(())
}

fn perform_inner(directory: &Path) -> Result<WorkloadOutcome, NativeFailure> {
    let large_file = directory.join("sequential.bin");
    let file =
        File::create(&large_file).map_err(|error| io_failure("workload", "create_file", error))?;
    let mut writer = BufWriter::new(file);
    let mut block = vec![0xA5_u8; 1_048_576];
    for index in 0..SEQUENTIAL_MEBIBYTES {
        block[0] = index as u8;
        writer
            .write_all(&block)
            .map_err(|error| io_failure("workload", "write_file", error))?;
    }
    writer
        .flush()
        .map_err(|error| io_failure("workload", "flush_file", error))?;
    writer
        .get_ref()
        .sync_all()
        .map_err(|error| io_failure("workload", "sync_file", error))?;
    drop(writer);

    let unbuffered_read = unbuffered_file::read(&large_file)?;

    let small_directory = directory.join("small-files");
    fs::create_dir_all(&small_directory)
        .map_err(|error| io_failure("workload", "create_small_directory", error))?;
    let payload = vec![0x5A_u8; 4_096];
    for index in 0..SMALL_FILE_COUNT {
        fs::write(small_directory.join(format!("item-{index}")), &payload)
            .map_err(|error| io_failure("workload", "write_small_file", error))?;
    }

    let executable = std::env::current_exe()
        .map_err(|error| io_failure("workload", "current_executable", error))?;
    let mut short_lived_processes = Vec::new();
    let mut short_lived_process_handles = Vec::new();
    for _ in 0..SHORT_LIVED_PROCESS_COUNT {
        let mut child = Command::new(&executable)
            .arg("--short-lived-read")
            .env(SHORT_LIVED_READ_PATH_ENV, &large_file)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| io_failure("workload", "spawn_short_process", error))?;
        let identity = match process::child_identity(&child) {
            Ok(identity) => identity,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let status = match child.wait() {
            Ok(status) => status,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io_failure("workload", "wait_short_process", error));
            }
        };
        if !status.success() {
            return Err(NativeFailure::new(
                "workload",
                "short_process_exit",
                status.code().unwrap_or(1) as u32,
            ));
        }
        short_lived_processes.push(identity);
        short_lived_process_handles.push(child);
    }

    Ok(WorkloadOutcome {
        report: WorkloadReport {
            attempted: true,
            completed: true,
            sequential_write_bytes: u64::from(SEQUENTIAL_MEBIBYTES) * 1_048_576,
            sequential_read_bytes: unbuffered_read.bytes,
            sequential_read_mode: Some("windows_unbuffered_file"),
            logical_sector_bytes: Some(unbuffered_read.logical_sector_bytes),
            physical_sector_bytes: Some(unbuffered_read.physical_sector_bytes),
            small_files_created: SMALL_FILE_COUNT,
            short_lived_processes_started: short_lived_processes.len() as u32,
            short_lived_process_read_bytes: (short_lived_processes.len() as u64)
                .saturating_mul(SHORT_LIVED_READ_BYTES),
            cleanup_succeeded: false,
        },
        short_lived_processes,
        short_lived_process_handles,
    })
}

fn io_failure(phase: &'static str, api: &'static str, error: std::io::Error) -> NativeFailure {
    NativeFailure::new(phase, api, error.raw_os_error().unwrap_or(1) as u32)
}

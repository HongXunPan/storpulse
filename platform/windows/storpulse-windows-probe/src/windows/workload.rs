use std::fs::{self, File};
use std::io::{BufWriter, Read, Write};
use std::path::Path;
use std::process::Command;

use crate::model::WorkloadReport;

use super::NativeFailure;

const SEQUENTIAL_MEBIBYTES: u32 = 64;
const SMALL_FILE_COUNT: u32 = 500;
const SHORT_LIVED_PROCESS_COUNT: u32 = 40;

pub fn perform(output_directory: &Path, skip: bool) -> Result<WorkloadReport, NativeFailure> {
    if skip {
        return Ok(WorkloadReport::default());
    }

    let workload_directory = output_directory.join("workload-active");
    let _ = fs::remove_dir_all(&workload_directory);
    fs::create_dir_all(&workload_directory)
        .map_err(|error| io_failure("workload", "create_directory", error))?;

    let result = perform_inner(&workload_directory);
    let cleanup_succeeded = fs::remove_dir_all(&workload_directory).is_ok();
    result.map(|mut report| {
        report.cleanup_succeeded = cleanup_succeeded;
        report
    })
}

fn perform_inner(directory: &Path) -> Result<WorkloadReport, NativeFailure> {
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

    let mut reader =
        File::open(&large_file).map_err(|error| io_failure("workload", "open_file", error))?;
    let mut read_buffer = vec![0_u8; 1_048_576];
    let mut sequential_read_bytes = 0_u64;
    loop {
        let read = reader
            .read(&mut read_buffer)
            .map_err(|error| io_failure("workload", "read_file", error))?;
        if read == 0 {
            break;
        }
        sequential_read_bytes = sequential_read_bytes.saturating_add(read as u64);
    }

    let small_directory = directory.join("small-files");
    fs::create_dir_all(&small_directory)
        .map_err(|error| io_failure("workload", "create_small_directory", error))?;
    let payload = vec![0x5A_u8; 4_096];
    for index in 0..SMALL_FILE_COUNT {
        fs::write(small_directory.join(format!("item-{index}")), &payload)
            .map_err(|error| io_failure("workload", "write_small_file", error))?;
    }

    let mut short_lived_processes_started = 0;
    for _ in 0..SHORT_LIVED_PROCESS_COUNT {
        let status = Command::new("cmd.exe")
            .args(["/D", "/Q", "/C", "exit", "0"])
            .status()
            .map_err(|error| io_failure("workload", "spawn_short_process", error))?;
        if status.success() {
            short_lived_processes_started += 1;
        }
    }

    Ok(WorkloadReport {
        attempted: true,
        completed: true,
        sequential_write_bytes: u64::from(SEQUENTIAL_MEBIBYTES) * 1_048_576,
        sequential_read_bytes,
        small_files_created: SMALL_FILE_COUNT,
        short_lived_processes_started,
        cleanup_succeeded: false,
    })
}

fn io_failure(phase: &'static str, api: &'static str, error: std::io::Error) -> NativeFailure {
    NativeFailure::new(phase, api, error.raw_os_error().unwrap_or(1) as u32)
}

use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};

use crate::WorkloadEvidence;

use super::{ClientError, unbuffered_file};

const SEQUENTIAL_MEBIBYTES: u32 = 32;
const MEBIBYTE_BYTES: u64 = 1_048_576;

pub(super) fn spawn(output_directory: PathBuf) -> Receiver<Result<WorkloadEvidence, ClientError>> {
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = sender.send(perform(&output_directory));
    });
    receiver
}

pub(super) fn perform(output_directory: &Path) -> Result<WorkloadEvidence, ClientError> {
    let workload_directory = output_directory.join("workload-active");
    match fs::remove_dir_all(&workload_directory) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(io_error("prepare_workload_directory_failed", error)),
    }
    fs::create_dir_all(&workload_directory)
        .map_err(|error| io_error("create_workload_directory_failed", error))?;

    let result = perform_inner(&workload_directory);
    let cleanup_succeeded = fs::remove_dir_all(&workload_directory).is_ok();
    result.map(|mut evidence| {
        evidence.cleanup_succeeded = cleanup_succeeded;
        evidence
    })
}

fn perform_inner(directory: &Path) -> Result<WorkloadEvidence, ClientError> {
    let path = directory.join("sequential.bin");
    let file =
        File::create(&path).map_err(|error| io_error("create_workload_file_failed", error))?;
    let mut writer = BufWriter::new(file);
    let mut block = vec![0xA5_u8; MEBIBYTE_BYTES as usize];
    for index in 0..SEQUENTIAL_MEBIBYTES {
        block[0] = index as u8;
        writer
            .write_all(&block)
            .map_err(|error| io_error("write_workload_file_failed", error))?;
    }
    writer
        .flush()
        .map_err(|error| io_error("flush_workload_file_failed", error))?;
    writer
        .get_ref()
        .sync_all()
        .map_err(|error| io_error("sync_workload_file_failed", error))?;
    drop(writer);

    let read = unbuffered_file::read(&path)?;
    Ok(WorkloadEvidence {
        attempted: true,
        completed: read.bytes == u64::from(SEQUENTIAL_MEBIBYTES) * MEBIBYTE_BYTES,
        write_bytes: u64::from(SEQUENTIAL_MEBIBYTES) * MEBIBYTE_BYTES,
        read_bytes: read.bytes,
        read_mode: Some("windows_unbuffered_file"),
        cleanup_succeeded: false,
    })
}

fn io_error(code: &'static str, error: std::io::Error) -> ClientError {
    ClientError::new(
        "workload",
        code,
        Some(error.raw_os_error().unwrap_or(1) as u32),
    )
}

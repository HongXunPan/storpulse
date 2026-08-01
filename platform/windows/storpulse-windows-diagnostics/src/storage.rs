use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::{DiagnosticEvent, DiagnosticSeverity};

pub const SERVICE_FALLBACK_MAX_RECORDS: usize = 16;
pub const SERVICE_FALLBACK_MAX_BYTES: usize = 64 * 1024;
const FILE_PREFIX: &str = "service-failure-";
const FILE_SUFFIX: &str = ".ndjson";
const MAX_NAME_ATTEMPTS: u8 = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageError {
    NotTerminalFailure,
    Encode,
    RecordTooLarge,
    CreateDirectory,
    CreateTemporary,
    WriteTemporary,
    CommitRecord,
    EnumerateRecords,
    EvictRecord,
    NameExhausted,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteOutcome {
    pub path: PathBuf,
    pub evicted_records: usize,
}

#[derive(Debug, Clone)]
pub struct ServiceFallbackStore {
    directory: PathBuf,
    maximum_records: usize,
    maximum_bytes: usize,
}

impl ServiceFallbackStore {
    pub fn product(directory: impl Into<PathBuf>) -> Self {
        Self::with_limits(
            directory,
            SERVICE_FALLBACK_MAX_RECORDS,
            SERVICE_FALLBACK_MAX_BYTES,
        )
    }

    pub fn with_limits(
        directory: impl Into<PathBuf>,
        maximum_records: usize,
        maximum_bytes: usize,
    ) -> Self {
        assert!(maximum_records > 0, "后备记录数量上限必须大于零");
        assert!(maximum_bytes > 0, "后备记录大小上限必须大于零");
        Self {
            directory: directory.into(),
            maximum_records,
            maximum_bytes,
        }
    }

    pub fn write_failure(&self, event: &DiagnosticEvent) -> Result<WriteOutcome, StorageError> {
        if event.severity != DiagnosticSeverity::Error || event.safe_error_code.is_none() {
            return Err(StorageError::NotTerminalFailure);
        }
        let mut bytes = serde_json::to_vec(event).map_err(|_| StorageError::Encode)?;
        bytes.push(b'\n');
        if bytes.len() > self.maximum_bytes {
            return Err(StorageError::RecordTooLarge);
        }
        fs::create_dir_all(&self.directory).map_err(|_| StorageError::CreateDirectory)?;
        let evicted_records = self.evict_for_new_record()?;
        let (temporary, destination, mut file) = self.create_unique_file(event)?;
        if file.write_all(&bytes).is_err() || file.sync_data().is_err() {
            drop(file);
            let _ = fs::remove_file(&temporary);
            return Err(StorageError::WriteTemporary);
        }
        drop(file);
        if fs::rename(&temporary, &destination).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(StorageError::CommitRecord);
        }
        Ok(WriteOutcome {
            path: destination,
            evicted_records,
        })
    }

    fn create_unique_file(
        &self,
        event: &DiagnosticEvent,
    ) -> Result<(PathBuf, PathBuf, std::fs::File), StorageError> {
        for attempt in 0..MAX_NAME_ATTEMPTS {
            let file_name = format!(
                "{FILE_PREFIX}{:020}-{:010}-{attempt:02}{FILE_SUFFIX}",
                event.timestamp_utc,
                std::process::id()
            );
            let destination = self.directory.join(&file_name);
            let temporary = self.directory.join(format!(".{file_name}.writing"));
            if destination.exists() {
                continue;
            }
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
            {
                Ok(file) => return Ok((temporary, destination, file)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => return Err(StorageError::CreateTemporary),
            }
        }
        Err(StorageError::NameExhausted)
    }

    fn evict_for_new_record(&self) -> Result<usize, StorageError> {
        let entries = fs::read_dir(&self.directory).map_err(|_| StorageError::EnumerateRecords)?;
        let mut records = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|_| StorageError::EnumerateRecords)?;
            if is_service_failure_name(&entry.file_name()) {
                records.push(entry.path());
            }
        }
        records.sort_by(|left, right| left.file_name().cmp(&right.file_name()));
        let retained_before_write = self.maximum_records.saturating_sub(1);
        let excess = records.len().saturating_sub(retained_before_write);
        for path in records.iter().take(excess) {
            fs::remove_file(path).map_err(|_| StorageError::EvictRecord)?;
        }
        Ok(excess)
    }
}

fn is_service_failure_name(value: &OsStr) -> bool {
    let Some(value) = value.to_str() else {
        return false;
    };
    if !value.starts_with(FILE_PREFIX) || !value.ends_with(FILE_SUFFIX) {
        return false;
    }
    let body = &value[FILE_PREFIX.len()..value.len() - FILE_SUFFIX.len()];
    let mut segments = body.split('-');
    matches!(
        (segments.next(), segments.next(), segments.next(), segments.next()),
        (Some(timestamp), Some(process), Some(attempt), None)
            if timestamp.len() == 20
                && process.len() == 10
                && attempt.len() == 2
                && timestamp.bytes().all(|byte| byte.is_ascii_digit())
                && process.bytes().all(|byte| byte.is_ascii_digit())
                && attempt.bytes().all(|byte| byte.is_ascii_digit())
    )
}

pub fn program_data_diagnostics_root(program_data: &Path) -> Option<PathBuf> {
    if !program_data.is_absolute() {
        return None;
    }
    Some(program_data.join("StorPulse").join("Diagnostics"))
}

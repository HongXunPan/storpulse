use std::alloc::{Layout, alloc, dealloc};
use std::fs::{File, OpenOptions};
use std::mem::size_of;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::ptr::NonNull;

use windows_sys::Win32::Foundation::{ERROR_INVALID_DATA, ERROR_INVALID_PARAMETER, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_NO_BUFFERING, FILE_FLAG_SEQUENTIAL_SCAN, FILE_STORAGE_INFO, FileStorageInfo,
    GetFileInformationByHandleEx, ReadFile,
};

use super::ClientError;

const READ_BLOCK_BYTES: usize = 1_048_576;

pub(super) struct UnbufferedReadReport {
    pub(super) bytes: u64,
}

struct StorageAlignment {
    logical_sector_bytes: u32,
    physical_sector_bytes: u32,
}

struct AlignedBuffer {
    pointer: NonNull<u8>,
    layout: Layout,
}

impl AlignedBuffer {
    fn new(size: usize, alignment: usize) -> Result<Self, ClientError> {
        let layout = Layout::from_size_align(size, alignment)
            .map_err(|_| ClientError::new("workload", "aligned_buffer_layout_failed", Some(87)))?;
        // SAFETY：layout 已验证，返回内存在 Drop 中使用同一 layout 释放。
        let pointer = NonNull::new(unsafe { alloc(layout) }).ok_or_else(|| {
            ClientError::new("workload", "aligned_buffer_allocation_failed", Some(8))
        })?;
        Ok(Self { pointer, layout })
    }

    fn as_mut_ptr(&mut self) -> *mut u8 {
        self.pointer.as_ptr()
    }
}

impl Drop for AlignedBuffer {
    fn drop(&mut self) {
        // SAFETY：pointer 由 alloc 使用 self.layout 创建，且仅在此释放一次。
        unsafe { dealloc(self.pointer.as_ptr(), self.layout) };
    }
}

pub(super) fn read(path: &Path) -> Result<UnbufferedReadReport, ClientError> {
    let metadata_file =
        File::open(path).map_err(|error| io_error("open_alignment_probe_failed", error))?;
    let file_bytes = metadata_file
        .metadata()
        .map_err(|error| io_error("read_file_metadata_failed", error))?
        .len();
    if file_bytes == 0 {
        return Err(ClientError::new(
            "workload",
            "invalid_unbuffered_read_length",
            Some(ERROR_INVALID_PARAMETER),
        ));
    }
    let alignment = query_storage_alignment(&metadata_file)?;
    drop(metadata_file);
    validate_alignment(file_bytes, &alignment)?;

    let reader = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN)
        .open(path)
        .map_err(|error| io_error("open_unbuffered_file_failed", error))?;
    let handle: HANDLE = reader.as_raw_handle();
    let mut buffer =
        AlignedBuffer::new(READ_BLOCK_BYTES, alignment.physical_sector_bytes as usize)?;
    let mut bytes = 0_u64;
    for _ in 0..(file_bytes / READ_BLOCK_BYTES as u64) {
        let mut bytes_read = 0_u32;
        // SAFETY：handle 有效；缓冲区按物理扇区对齐且大小是逻辑扇区整数倍。
        let succeeded = unsafe {
            ReadFile(
                handle,
                buffer.as_mut_ptr(),
                READ_BLOCK_BYTES as u32,
                &mut bytes_read,
                std::ptr::null_mut(),
            )
        };
        if succeeded == 0 {
            return Err(ClientError::new(
                "workload",
                "unbuffered_read_failed",
                Some(unsafe { windows_sys::Win32::Foundation::GetLastError() }),
            ));
        }
        if bytes_read != READ_BLOCK_BYTES as u32 {
            return Err(ClientError::new(
                "workload",
                "short_unbuffered_read",
                Some(ERROR_INVALID_DATA),
            ));
        }
        bytes = bytes.saturating_add(u64::from(bytes_read));
    }
    Ok(UnbufferedReadReport { bytes })
}

fn validate_alignment(file_bytes: u64, alignment: &StorageAlignment) -> Result<(), ClientError> {
    let logical = alignment.logical_sector_bytes as usize;
    let physical = alignment.physical_sector_bytes as usize;
    if logical == 0
        || !logical.is_power_of_two()
        || physical == 0
        || !physical.is_power_of_two()
        || !READ_BLOCK_BYTES.is_multiple_of(logical)
        || !file_bytes.is_multiple_of(READ_BLOCK_BYTES as u64)
    {
        return Err(ClientError::new(
            "workload",
            "invalid_unbuffered_alignment",
            Some(ERROR_INVALID_PARAMETER),
        ));
    }
    Ok(())
}

fn query_storage_alignment(file: &File) -> Result<StorageAlignment, ClientError> {
    let mut storage_info = FILE_STORAGE_INFO::default();
    // SAFETY：文件句柄有效；输出缓冲区与 FileStorageInfo 结构和大小匹配。
    if unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            FileStorageInfo,
            (&mut storage_info as *mut FILE_STORAGE_INFO).cast(),
            size_of::<FILE_STORAGE_INFO>() as u32,
        )
    } == 0
    {
        return Err(ClientError::new(
            "workload",
            "query_storage_alignment_failed",
            Some(unsafe { windows_sys::Win32::Foundation::GetLastError() }),
        ));
    }
    Ok(StorageAlignment {
        logical_sector_bytes: storage_info.LogicalBytesPerSector,
        physical_sector_bytes: storage_info
            .PhysicalBytesPerSectorForAtomicity
            .max(storage_info.PhysicalBytesPerSectorForPerformance),
    })
}

fn io_error(code: &'static str, error: std::io::Error) -> ClientError {
    ClientError::new(
        "workload",
        code,
        Some(error.raw_os_error().unwrap_or(1) as u32),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_common_storage_alignment() {
        let alignment = StorageAlignment {
            logical_sector_bytes: 512,
            physical_sector_bytes: 4_096,
        };
        assert!(validate_alignment(32 * READ_BLOCK_BYTES as u64, &alignment).is_ok());
        assert!(validate_alignment(READ_BLOCK_BYTES as u64 - 1, &alignment).is_err());
    }
}

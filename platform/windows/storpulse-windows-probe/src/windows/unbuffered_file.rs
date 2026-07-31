use std::alloc::{Layout, alloc, dealloc};
use std::fs::{File, OpenOptions};
use std::mem::{size_of, size_of_val};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::ptr::NonNull;

use windows_sys::Win32::Foundation::{
    ERROR_INVALID_DATA, ERROR_INVALID_PARAMETER, ERROR_NOT_ENOUGH_MEMORY, HANDLE,
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_NO_BUFFERING, FILE_FLAG_SEQUENTIAL_SCAN, ReadFile,
};
use windows_sys::Win32::System::IO::DeviceIoControl;
use windows_sys::Win32::System::Ioctl::{
    IOCTL_STORAGE_QUERY_PROPERTY, PropertyStandardQuery, STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR,
    STORAGE_PROPERTY_QUERY, StorageAccessAlignmentProperty,
};

use super::NativeFailure;

const READ_BLOCK_BYTES: usize = 1_048_576;

struct StorageAlignment {
    logical_sector_bytes: u32,
    physical_sector_bytes: u32,
}

pub(super) struct UnbufferedReadReport {
    pub(super) bytes: u64,
    pub(super) logical_sector_bytes: u32,
    pub(super) physical_sector_bytes: u32,
}

struct AlignedBuffer {
    pointer: NonNull<u8>,
    layout: Layout,
}

impl AlignedBuffer {
    fn new(size: usize, alignment: usize) -> Result<Self, NativeFailure> {
        let layout = Layout::from_size_align(size, alignment).map_err(|_| {
            NativeFailure::new("workload", "aligned_buffer_layout", ERROR_INVALID_PARAMETER)
        })?;
        // SAFETY：layout 已验证，返回内存在 Drop 中使用同一 layout 释放。
        let pointer = NonNull::new(unsafe { alloc(layout) }).ok_or_else(|| {
            NativeFailure::new("workload", "aligned_buffer_alloc", ERROR_NOT_ENOUGH_MEMORY)
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

pub(super) fn read(path: &Path) -> Result<UnbufferedReadReport, NativeFailure> {
    let metadata_file = File::open(path)
        .map_err(|error| io_failure("workload", "open_alignment_probe", error))?;
    let file_bytes = metadata_file
        .metadata()
        .map_err(|error| io_failure("workload", "read_file_metadata", error))?
        .len();
    let alignment = query_storage_alignment(&metadata_file)?;
    drop(metadata_file);

    let physical_sector_bytes = alignment.physical_sector_bytes as usize;
    validate_alignment(file_bytes, &alignment)?;

    let reader = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN)
        .open(path)
        .map_err(|error| io_failure("workload", "open_unbuffered_file", error))?;
    let handle: HANDLE = reader.as_raw_handle();
    let mut buffer = AlignedBuffer::new(READ_BLOCK_BYTES, physical_sector_bytes)?;
    let mut bytes = 0_u64;
    for _ in 0..(file_bytes / READ_BLOCK_BYTES as u64) {
        let mut bytes_read = 0_u32;
        // SAFETY：handle 有效；缓冲区按物理扇区对齐且大小是逻辑扇区整数倍；同步读取不使用 OVERLAPPED。
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
            return Err(NativeFailure::last("workload", "ReadFile.unbuffered"));
        }
        if bytes_read != READ_BLOCK_BYTES as u32 {
            return Err(NativeFailure::new(
                "workload",
                "ReadFile.short_unbuffered",
                ERROR_INVALID_DATA,
            ));
        }
        bytes = bytes.saturating_add(u64::from(bytes_read));
    }

    Ok(UnbufferedReadReport {
        bytes,
        logical_sector_bytes: alignment.logical_sector_bytes,
        physical_sector_bytes: alignment.physical_sector_bytes,
    })
}

fn validate_alignment(
    file_bytes: u64,
    alignment: &StorageAlignment,
) -> Result<(), NativeFailure> {
    let logical_sector_bytes = alignment.logical_sector_bytes as usize;
    let physical_sector_bytes = alignment.physical_sector_bytes as usize;
    if logical_sector_bytes == 0
        || !logical_sector_bytes.is_power_of_two()
        || physical_sector_bytes == 0
        || !physical_sector_bytes.is_power_of_two()
        || !READ_BLOCK_BYTES.is_multiple_of(logical_sector_bytes)
        || !file_bytes.is_multiple_of(READ_BLOCK_BYTES as u64)
    {
        return Err(NativeFailure::new(
            "workload",
            "validate_unbuffered_alignment",
            ERROR_INVALID_PARAMETER,
        ));
    }
    Ok(())
}

fn query_storage_alignment(file: &File) -> Result<StorageAlignment, NativeFailure> {
    let query = STORAGE_PROPERTY_QUERY {
        PropertyId: StorageAccessAlignmentProperty,
        QueryType: PropertyStandardQuery,
        AdditionalParameters: [0],
    };
    let mut descriptor = STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR::default();
    let mut bytes_returned = 0_u32;
    // SAFETY：文件句柄有效；输入输出结构与 IOCTL_STORAGE_QUERY_PROPERTY 契约匹配。
    let succeeded = unsafe {
        DeviceIoControl(
            file.as_raw_handle(),
            IOCTL_STORAGE_QUERY_PROPERTY,
            (&query as *const STORAGE_PROPERTY_QUERY).cast(),
            size_of_val(&query) as u32,
            (&mut descriptor as *mut STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR).cast(),
            size_of_val(&descriptor) as u32,
            &mut bytes_returned,
            std::ptr::null_mut(),
        )
    };
    if succeeded == 0 {
        return Err(NativeFailure::last(
            "workload",
            "DeviceIoControl.StorageAccessAlignment",
        ));
    }
    if bytes_returned < size_of::<STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR>() as u32
        || descriptor.BytesPerLogicalSector == 0
        || descriptor.BytesPerPhysicalSector == 0
    {
        return Err(NativeFailure::new(
            "workload",
            "StorageAccessAlignment.invalid",
            ERROR_INVALID_DATA,
        ));
    }

    Ok(StorageAlignment {
        logical_sector_bytes: descriptor.BytesPerLogicalSector,
        physical_sector_bytes: descriptor.BytesPerPhysicalSector,
    })
}

fn io_failure(phase: &'static str, api: &'static str, error: std::io::Error) -> NativeFailure {
    NativeFailure::new(phase, api, error.raw_os_error().unwrap_or(1) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_common_sector_alignment() {
        let alignment = StorageAlignment {
            logical_sector_bytes: 512,
            physical_sector_bytes: 4096,
        };

        assert!(validate_alignment(64 * READ_BLOCK_BYTES as u64, &alignment).is_ok());
    }

    #[test]
    fn rejects_partial_unbuffered_block() {
        let alignment = StorageAlignment {
            logical_sector_bytes: 512,
            physical_sector_bytes: 4096,
        };

        assert!(validate_alignment(READ_BLOCK_BYTES as u64 - 1, &alignment).is_err());
    }

    #[test]
    fn allocated_buffer_matches_physical_sector_alignment() {
        let mut buffer = match AlignedBuffer::new(READ_BLOCK_BYTES, 4096) {
            Ok(buffer) => buffer,
            Err(_) => panic!("应成功分配对齐缓冲区"),
        };

        assert_eq!(buffer.as_mut_ptr() as usize % 4096, 0);
    }
}

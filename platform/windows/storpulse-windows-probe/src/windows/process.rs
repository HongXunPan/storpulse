use std::os::windows::io::AsRawHandle;
use std::process::Child;

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_ACCESS_DENIED, ERROR_INVALID_HANDLE, ERROR_INVALID_PARAMETER, FILETIME,
    GetLastError, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::ProcessStatus::{
    K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX,
};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetProcessIoCounters, GetProcessTimes, IO_COUNTERS, OpenProcess,
    PROCESS_QUERY_LIMITED_INFORMATION,
};

use crate::model::{NativeIoCounters, ProcessMeasurements, ProcessScanReport};

use super::NativeFailure;

#[derive(Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProcessIdentity {
    pub(super) process_id: u32,
    pub(super) start_time_ticks: u64,
}

pub fn current_process() -> Result<ProcessMeasurements, NativeFailure> {
    // SAFETY：GetCurrentProcess 返回无需关闭的伪句柄。
    let handle = unsafe { GetCurrentProcess() };
    read_measurements(handle, std::process::id(), true)
}

pub(super) fn child_identity(child: &Child) -> Result<ProcessIdentity, NativeFailure> {
    let handle: HANDLE = child.as_raw_handle();
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // SAFETY：Child 在调用期间持有有效进程句柄，所有 FILETIME 输出缓冲区均有效。
    if unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) } == 0 {
        return Err(NativeFailure::last(
            "workload",
            "GetProcessTimes.short_lived_child",
        ));
    }
    Ok(ProcessIdentity {
        process_id: child.id(),
        start_time_ticks: filetime_ticks(creation),
    })
}

pub fn scan_processes() -> Result<ProcessScanReport, NativeFailure> {
    // SAFETY：请求只读进程快照，返回句柄会在本函数内关闭。
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(NativeFailure::new(
            "process_scan",
            "CreateToolhelp32Snapshot",
            unsafe { GetLastError() },
        ));
    }

    let mut report = ProcessScanReport::default();
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    // SAFETY：entry 的 dwSize 已设置，snapshot 在迭代期间保持有效。
    let mut has_entry = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
    while has_entry {
        report.discovered_processes += 1;
        inspect_process(entry.th32ProcessID, &mut report);
        // SAFETY：与 Process32FirstW 使用相同的有效快照和缓冲区。
        has_entry = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
    }
    // SAFETY：snapshot 是本函数创建的有效句柄。
    unsafe { CloseHandle(snapshot) };
    Ok(report)
}

fn inspect_process(process_id: u32, report: &mut ProcessScanReport) {
    // SAFETY：只申请受限查询权限，不继承句柄。
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) };
    if handle.is_null() {
        let code = unsafe { GetLastError() };
        match code {
            ERROR_ACCESS_DENIED => report.restricted_processes += 1,
            ERROR_INVALID_HANDLE | ERROR_INVALID_PARAMETER => report.exited_processes += 1,
            _ => report.other_failures += 1,
        }
        return;
    }

    match read_measurements(handle, process_id, false) {
        Ok(measurements) => {
            report.readable_processes += 1;
            report.broad_io_read_bytes = report
                .broad_io_read_bytes
                .saturating_add(measurements.io.read_bytes);
            report.broad_io_write_bytes = report
                .broad_io_write_bytes
                .saturating_add(measurements.io.write_bytes);
        }
        Err(error) if error.code == ERROR_ACCESS_DENIED => report.restricted_processes += 1,
        Err(error) if error.code == ERROR_INVALID_HANDLE => report.exited_processes += 1,
        Err(_) => report.other_failures += 1,
    }
    // SAFETY：handle 是 OpenProcess 返回的有效句柄。
    unsafe { CloseHandle(handle) };
}

fn read_measurements(
    handle: HANDLE,
    process_id: u32,
    include_memory: bool,
) -> Result<ProcessMeasurements, NativeFailure> {
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // SAFETY：所有 FILETIME 输出缓冲区均有效。
    if unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) } == 0 {
        return Err(NativeFailure::last(
            "process_measurement",
            "GetProcessTimes",
        ));
    }

    let mut io = IO_COUNTERS::default();
    // SAFETY：IO_COUNTERS 输出缓冲区大小与 API 契约一致。
    if unsafe { GetProcessIoCounters(handle, &mut io) } == 0 {
        return Err(NativeFailure::last(
            "process_measurement",
            "GetProcessIoCounters",
        ));
    }

    let (working_set_bytes, private_bytes) = if include_memory {
        process_memory(handle)
    } else {
        (0, 0)
    };
    Ok(ProcessMeasurements {
        process_id,
        start_time_ticks: filetime_ticks(creation),
        kernel_time_ticks: filetime_ticks(kernel),
        user_time_ticks: filetime_ticks(user),
        working_set_bytes,
        private_bytes,
        io: NativeIoCounters {
            read_operations: io.ReadOperationCount,
            write_operations: io.WriteOperationCount,
            other_operations: io.OtherOperationCount,
            read_bytes: io.ReadTransferCount,
            write_bytes: io.WriteTransferCount,
            other_bytes: io.OtherTransferCount,
        },
    })
}

fn process_memory(handle: HANDLE) -> (u64, u64) {
    let mut counters = PROCESS_MEMORY_COUNTERS_EX {
        cb: std::mem::size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
        ..Default::default()
    };
    // SAFETY：EX 结构以基础结构开头，传入完整大小以取得 PrivateUsage。
    let succeeded = unsafe {
        K32GetProcessMemoryInfo(
            handle,
            (&mut counters as *mut PROCESS_MEMORY_COUNTERS_EX).cast::<PROCESS_MEMORY_COUNTERS>(),
            std::mem::size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
        )
    };
    if succeeded == 0 {
        return (0, 0);
    }
    (counters.WorkingSetSize as u64, counters.PrivateUsage as u64)
}

fn filetime_ticks(value: FILETIME) -> u64 {
    u64::from(value.dwLowDateTime) | (u64::from(value.dwHighDateTime) << 32)
}

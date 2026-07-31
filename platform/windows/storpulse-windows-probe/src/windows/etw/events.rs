use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::sync::{Arc, Mutex};

use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Diagnostics::Etw::{
    DiskIoGuid, EVENT_HEADER_FLAG_32_BIT_HEADER, EVENT_RECORD, ProcessGuid, ThreadGuid,
};

use crate::model::{EtwEventReport, ProcessDiskIoReport};

use super::super::process::ProcessIdentity;

pub(super) struct CallbackContext {
    pub stats: Arc<Mutex<EventStats>>,
}

pub(super) struct SessionCompletion {
    pub stop_status: u32,
    pub process_status: u32,
    pub events_lost: u32,
    pub log_buffers_lost: u32,
    pub realtime_buffers_lost: u32,
}

#[derive(Default)]
pub(super) struct EventStats {
    report: EtwEventReport,
    thread_to_process: HashMap<u32, u32>,
    process_io: HashMap<u32, ProcessIo>,
    process_start_ids: HashSet<u32>,
    process_end_ids: HashSet<u32>,
}

#[derive(Default)]
struct ProcessIo {
    read_bytes: u64,
    write_bytes: u64,
    read_events: u64,
    write_events: u64,
}

pub(super) unsafe extern "system" fn event_record_callback(event_record: *mut EVENT_RECORD) {
    if event_record.is_null() {
        return;
    }
    // SAFETY：ETW 保证回调期间 EVENT_RECORD 及 UserContext 有效。
    let event = unsafe { &*event_record };
    if event.UserContext.is_null() {
        return;
    }
    let context = unsafe { &*(event.UserContext as *const CallbackContext) };
    let mut stats = context
        .stats
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    stats.observe(event);
}

impl EventStats {
    fn observe(&mut self, event: &EVENT_RECORD) {
        self.report.total_events = self.report.total_events.saturating_add(1);
        let opcode = event.EventHeader.EventDescriptor.Opcode;
        if same_guid(&event.EventHeader.ProviderId, &ThreadGuid) {
            self.observe_thread(event, opcode);
        } else if same_guid(&event.EventHeader.ProviderId, &ProcessGuid) {
            self.observe_process(event, opcode);
        } else if same_guid(&event.EventHeader.ProviderId, &DiskIoGuid) {
            self.observe_disk(event, opcode);
        }
    }

    fn observe_process(&mut self, event: &EVENT_RECORD, opcode: u8) {
        self.report.process_events = self.report.process_events.saturating_add(1);
        if !matches!(opcode, 1 | 2) {
            return;
        }
        let Some(process_id) =
            read_u32(event, process_id_offset(u32::from(event.EventHeader.Flags)))
        else {
            self.report.short_payload_events = self.report.short_payload_events.saturating_add(1);
            return;
        };
        if opcode == 1 {
            self.process_start_ids.insert(process_id);
        } else {
            self.process_end_ids.insert(process_id);
        }
    }

    fn observe_thread(&mut self, event: &EVENT_RECORD, opcode: u8) {
        self.report.thread_events = self.report.thread_events.saturating_add(1);
        let process_id = read_u32(event, 0);
        let thread_id = read_u32(event, 4);
        if let (Some(process_id), Some(thread_id)) = (process_id, thread_id) {
            match opcode {
                1 | 3 => {
                    self.thread_to_process.insert(thread_id, process_id);
                }
                2 | 4 => {
                    self.thread_to_process.remove(&thread_id);
                }
                _ => {}
            }
        }
    }

    fn observe_disk(&mut self, event: &EVENT_RECORD, opcode: u8) {
        self.report.disk_events = self.report.disk_events.saturating_add(1);
        let count = self.report.events_by_opcode.entry(opcode).or_default();
        *count = count.saturating_add(1);
        if !matches!(opcode, 10 | 11) {
            return;
        }
        let Some(transfer_size) = read_u32(event, 8) else {
            self.report.short_payload_events = self.report.short_payload_events.saturating_add(1);
            return;
        };
        let issuing_thread_offset =
            if u32::from(event.EventHeader.Flags) & EVENT_HEADER_FLAG_32_BIT_HEADER != 0 {
                40
            } else {
                48
            };
        let thread_id =
            read_u32(event, issuing_thread_offset).unwrap_or(event.EventHeader.ThreadId);
        let Some(process_id) = self.thread_to_process.get(&thread_id).copied() else {
            self.report.unmapped_disk_events = self.report.unmapped_disk_events.saturating_add(1);
            return;
        };
        self.report.mapped_disk_events = self.report.mapped_disk_events.saturating_add(1);
        let process = self.process_io.entry(process_id).or_default();
        if opcode == 10 {
            self.report.disk_read_events = self.report.disk_read_events.saturating_add(1);
            self.report.disk_read_bytes = self
                .report
                .disk_read_bytes
                .saturating_add(u64::from(transfer_size));
            process.read_events = process.read_events.saturating_add(1);
            process.read_bytes = process.read_bytes.saturating_add(u64::from(transfer_size));
        } else {
            self.report.disk_write_events = self.report.disk_write_events.saturating_add(1);
            self.report.disk_write_bytes = self
                .report
                .disk_write_bytes
                .saturating_add(u64::from(transfer_size));
            process.write_events = process.write_events.saturating_add(1);
            process.write_bytes = process.write_bytes.saturating_add(u64::from(transfer_size));
        }
    }

    pub fn finish(
        &mut self,
        probe_process_id: u32,
        short_lived_processes: &[ProcessIdentity],
        completion: SessionCompletion,
    ) -> EtwEventReport {
        self.report.session_started = true;
        self.report.consumer_started = true;
        self.report.start_status = ERROR_SUCCESS;
        self.report.open_status = ERROR_SUCCESS;
        self.report.stop_status = completion.stop_status;
        self.report.process_status = completion.process_status;
        self.report.events_lost = completion.events_lost;
        self.report.log_buffers_lost = completion.log_buffers_lost;
        self.report.realtime_buffers_lost = completion.realtime_buffers_lost;

        let mut report = self.report.clone();
        self.correlate_short_lived_processes(&mut report, short_lived_processes);
        let mut processes: Vec<_> = self
            .process_io
            .iter()
            .map(|(&process_id, io)| ProcessDiskIoReport {
                process_id,
                is_probe: process_id == probe_process_id,
                read_bytes: io.read_bytes,
                write_bytes: io.write_bytes,
                read_events: io.read_events,
                write_events: io.write_events,
            })
            .collect();
        processes.sort_by_key(|process| {
            std::cmp::Reverse(process.read_bytes.saturating_add(process.write_bytes))
        });
        processes.truncate(20);
        report.top_processes = processes;
        report
    }

    fn correlate_short_lived_processes(
        &self,
        report: &mut EtwEventReport,
        identities: &[ProcessIdentity],
    ) {
        let unique_identities: HashSet<_> = identities
            .iter()
            .map(|identity| (identity.process_id, identity.start_time_ticks))
            .collect();
        let process_ids: HashSet<_> = identities
            .iter()
            .map(|identity| identity.process_id)
            .collect();
        report.short_lived_processes_expected = identities.len() as u32;
        report.short_lived_process_identities = unique_identities.len() as u32;
        report.short_lived_pid_reuse_detected = process_ids.len() != unique_identities.len();

        for process_id in process_ids {
            if self.process_start_ids.contains(&process_id) {
                report.short_lived_process_start_matches =
                    report.short_lived_process_start_matches.saturating_add(1);
            }
            if self.process_end_ids.contains(&process_id) {
                report.short_lived_process_end_matches =
                    report.short_lived_process_end_matches.saturating_add(1);
            }
            if let Some(io) = self.process_io.get(&process_id)
                && io.read_events.saturating_add(io.write_events) > 0
            {
                report.short_lived_process_io_matches =
                    report.short_lived_process_io_matches.saturating_add(1);
                report.short_lived_process_read_bytes = report
                    .short_lived_process_read_bytes
                    .saturating_add(io.read_bytes);
                report.short_lived_process_write_bytes = report
                    .short_lived_process_write_bytes
                    .saturating_add(io.write_bytes);
            }
        }
    }
}

fn process_id_offset(header_flags: u32) -> usize {
    if header_flags & EVENT_HEADER_FLAG_32_BIT_HEADER != 0 {
        4
    } else {
        8
    }
}

fn read_u32(event: &EVENT_RECORD, offset: usize) -> Option<u32> {
    if event.UserData.is_null() || usize::from(event.UserDataLength) < offset + size_of::<u32>() {
        return None;
    }
    // SAFETY：长度检查保证 offset 后至少有 4 字节；使用 unaligned 读取避免对齐假设。
    Some(unsafe {
        std::ptr::read_unaligned((event.UserData as *const u8).add(offset).cast::<u32>())
    })
}

fn same_guid(left: &windows_sys::core::GUID, right: &windows_sys::core::GUID) -> bool {
    left.data1 == right.data1
        && left.data2 == right.data2
        && left.data3 == right.data3
        && left.data4 == right.data4
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_payload_pid_offset_follows_header_bitness() {
        assert_eq!(process_id_offset(EVENT_HEADER_FLAG_32_BIT_HEADER), 4);
        assert_eq!(process_id_offset(0), 8);
    }

    #[test]
    fn correlates_short_lived_processes_without_persisting_identity_details() {
        let mut stats = EventStats::default();
        stats.process_start_ids.extend([101, 102]);
        stats.process_end_ids.extend([101, 102]);
        stats.process_io.insert(
            101,
            ProcessIo {
                read_bytes: 1_048_576,
                read_events: 1,
                ..Default::default()
            },
        );
        stats.process_io.insert(
            102,
            ProcessIo {
                read_bytes: 1_048_576,
                read_events: 1,
                ..Default::default()
            },
        );
        let identities = vec![
            ProcessIdentity {
                process_id: 101,
                start_time_ticks: 1,
            },
            ProcessIdentity {
                process_id: 102,
                start_time_ticks: 2,
            },
        ];
        let mut report = EtwEventReport::default();

        stats.correlate_short_lived_processes(&mut report, &identities);

        assert_eq!(report.short_lived_processes_expected, 2);
        assert_eq!(report.short_lived_process_identities, 2);
        assert_eq!(report.short_lived_process_start_matches, 2);
        assert_eq!(report.short_lived_process_end_matches, 2);
        assert_eq!(report.short_lived_process_io_matches, 2);
        assert_eq!(report.short_lived_process_read_bytes, 2_097_152);
        assert!(!report.short_lived_pid_reuse_detected);
    }
}

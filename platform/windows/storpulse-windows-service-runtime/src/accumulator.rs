use std::collections::{BTreeMap, HashMap, HashSet};

use storpulse_core::model::{
    CollectionSummary, Completeness, DeviceIoSample, Freshness, MetricScope, ProcessIdentity,
    ProcessIoSample, RawSnapshot, SNAPSHOT_SCHEMA_VERSION,
};

use crate::{CollectorEvent, DiskOperation, ProcessDescriptor, ProcessMetrics};

const METRIC_SOURCE: &str = "windows.localsystem-service.etw-system-diskio";
type ProcessKey = (i32, u64);

#[derive(Debug, Default)]
pub struct SessionAccumulator {
    processes: HashMap<ProcessKey, ProcessRecord>,
    current_identity_by_pid: HashMap<i32, ProcessKey>,
    process_by_thread: HashMap<u32, ProcessKey>,
    devices: BTreeMap<u32, DeviceCounters>,
    pending_exits: HashSet<ProcessKey>,
    restricted_processes: HashSet<i32>,
    unmapped_disk_events: u64,
    events_lost: u64,
    buffers_lost: u64,
}

impl SessionAccumulator {
    pub fn observe(&mut self, event: CollectorEvent) {
        match event {
            CollectorEvent::ProcessObserved(descriptor) => self.observe_process(descriptor),
            CollectorEvent::ProcessEnded { process_id } => self.end_process(process_id),
            CollectorEvent::ProcessRestricted { process_id } => {
                if !self.current_identity_by_pid.contains_key(&process_id) {
                    self.restricted_processes.insert(process_id);
                }
            }
            CollectorEvent::ThreadAssigned {
                thread_id,
                process_id,
            } => {
                if let Some(identity) = self.current_identity_by_pid.get(&process_id).copied() {
                    self.process_by_thread.insert(thread_id, identity);
                }
            }
            CollectorEvent::ThreadEnded { thread_id } => {
                self.process_by_thread.remove(&thread_id);
            }
            CollectorEvent::DiskIo {
                disk_number,
                thread_id,
                operation,
                transfer_bytes,
            } => self.observe_disk_io(disk_number, thread_id, operation, transfer_bytes),
            CollectorEvent::TraceLoss { events, buffers } => {
                self.events_lost = self.events_lost.saturating_add(events);
                self.buffers_lost = self.buffers_lost.saturating_add(buffers);
            }
        }
    }

    pub fn snapshot(
        &mut self,
        captured_at: String,
        monotonic_nanoseconds: u64,
        collection_duration_nanoseconds: u64,
    ) -> RawSnapshot {
        let mut processes: Vec<_> = self.processes.values().map(ProcessRecord::sample).collect();
        processes.sort_by_key(|sample| (sample.identity.pid, sample.identity.start_time_ticks));
        let devices: Vec<_> = self
            .devices
            .iter()
            .map(|(disk_number, counters)| counters.sample(*disk_number))
            .collect();
        let exited_processes = self.pending_exits.len();
        let completeness = if self.restricted_processes.is_empty()
            && self.unmapped_disk_events == 0
            && self.events_lost == 0
            && self.buffers_lost == 0
        {
            Completeness::Complete
        } else {
            Completeness::Partial
        };
        let snapshot = RawSnapshot {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            captured_at,
            monotonic_nanoseconds,
            metric_source: METRIC_SOURCE.to_owned(),
            metric_scope: vec![MetricScope::Device, MetricScope::StorageProcess],
            freshness: Freshness::Fresh,
            completeness,
            summary: CollectionSummary {
                discovered_processes: processes.len() + self.restricted_processes.len(),
                readable_processes: processes.len(),
                restricted_processes: self.restricted_processes.len(),
                exited_processes,
                device_count: devices.len(),
                collection_duration_nanoseconds,
                unmapped_disk_events: self.unmapped_disk_events,
                events_lost: self.events_lost,
                buffers_lost: self.buffers_lost,
            },
            processes,
            devices,
        };
        self.prune_reported_exits();
        snapshot
    }

    fn observe_process(&mut self, descriptor: ProcessDescriptor) {
        let key = identity_key(&descriptor.identity);
        if let Some(previous) = self
            .current_identity_by_pid
            .insert(descriptor.identity.pid, key)
            && previous != key
        {
            self.pending_exits.insert(previous);
        }
        self.restricted_processes.remove(&descriptor.identity.pid);
        self.processes
            .entry(key)
            .and_modify(|process| process.update_metadata(&descriptor))
            .or_insert_with(|| ProcessRecord::new(descriptor));
    }

    fn end_process(&mut self, process_id: i32) {
        if let Some(key) = self.current_identity_by_pid.get(&process_id).copied() {
            self.pending_exits.insert(key);
        }
        self.restricted_processes.remove(&process_id);
    }

    fn observe_disk_io(
        &mut self,
        disk_number: u32,
        thread_id: u32,
        operation: DiskOperation,
        transfer_bytes: u64,
    ) {
        self.devices
            .entry(disk_number)
            .or_default()
            .observe(operation, transfer_bytes);
        let Some(process) = self
            .process_by_thread
            .get(&thread_id)
            .and_then(|identity| self.processes.get_mut(identity))
        else {
            self.unmapped_disk_events = self.unmapped_disk_events.saturating_add(1);
            return;
        };
        process.observe(operation, transfer_bytes);
    }

    fn prune_reported_exits(&mut self) {
        for key in self.pending_exits.drain() {
            self.processes.remove(&key);
            self.process_by_thread
                .retain(|_, identity| *identity != key);
            if self.current_identity_by_pid.get(&key.0) == Some(&key) {
                self.current_identity_by_pid.remove(&key.0);
            }
        }
    }
}

#[derive(Debug)]
struct ProcessRecord {
    identity: ProcessIdentity,
    parent_pid: Option<i32>,
    executable_name: String,
    metrics: ProcessMetrics,
    read_bytes: u64,
    write_bytes: u64,
}

impl ProcessRecord {
    fn new(descriptor: ProcessDescriptor) -> Self {
        Self {
            identity: descriptor.identity,
            parent_pid: descriptor.parent_pid,
            executable_name: descriptor.executable_name,
            metrics: descriptor.metrics,
            read_bytes: 0,
            write_bytes: 0,
        }
    }

    fn update_metadata(&mut self, descriptor: &ProcessDescriptor) {
        self.parent_pid = descriptor.parent_pid;
        self.executable_name.clone_from(&descriptor.executable_name);
        self.metrics = descriptor.metrics;
    }

    fn observe(&mut self, operation: DiskOperation, transfer_bytes: u64) {
        match operation {
            DiskOperation::Read => self.read_bytes = self.read_bytes.saturating_add(transfer_bytes),
            DiskOperation::Write => {
                self.write_bytes = self.write_bytes.saturating_add(transfer_bytes)
            }
        }
    }

    fn sample(&self) -> ProcessIoSample {
        ProcessIoSample {
            identity: self.identity.clone(),
            parent_pid: self.parent_pid,
            executable_name: self.executable_name.clone(),
            application_id: None,
            application_name: None,
            is_helper: false,
            launched_by_application_id: None,
            read_bytes: self.read_bytes,
            write_bytes: self.write_bytes,
            user_time_nanoseconds: self.metrics.user_time_nanoseconds,
            system_time_nanoseconds: self.metrics.system_time_nanoseconds,
            resident_bytes: self.metrics.resident_bytes,
            physical_footprint_bytes: self.metrics.physical_footprint_bytes,
        }
    }
}

#[derive(Debug, Default)]
struct DeviceCounters {
    read_bytes: u64,
    write_bytes: u64,
    read_operations: u64,
    write_operations: u64,
}

impl DeviceCounters {
    fn observe(&mut self, operation: DiskOperation, transfer_bytes: u64) {
        match operation {
            DiskOperation::Read => {
                self.read_bytes = self.read_bytes.saturating_add(transfer_bytes);
                self.read_operations = self.read_operations.saturating_add(1);
            }
            DiskOperation::Write => {
                self.write_bytes = self.write_bytes.saturating_add(transfer_bytes);
                self.write_operations = self.write_operations.saturating_add(1);
            }
        }
    }

    fn sample(&self, disk_number: u32) -> DeviceIoSample {
        DeviceIoSample {
            device_id: format!("windows:disk:{disk_number}"),
            read_bytes: self.read_bytes,
            write_bytes: self.write_bytes,
            read_operations: Some(self.read_operations),
            write_operations: Some(self.write_operations),
        }
    }
}

fn identity_key(identity: &ProcessIdentity) -> ProcessKey {
    (identity.pid, identity.start_time_ticks)
}

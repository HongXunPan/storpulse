use storpulse_core::model::ProcessIdentity;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProcessMetrics {
    pub user_time_nanoseconds: Option<u64>,
    pub system_time_nanoseconds: Option<u64>,
    pub resident_bytes: Option<u64>,
    pub physical_footprint_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessDescriptor {
    pub identity: ProcessIdentity,
    pub parent_pid: Option<i32>,
    pub executable_name: String,
    pub metrics: ProcessMetrics,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskOperation {
    Read,
    Write,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CollectorEvent {
    ProcessObserved(ProcessDescriptor),
    ProcessEnded {
        process_id: i32,
    },
    ProcessRestricted {
        process_id: i32,
    },
    ThreadAssigned {
        thread_id: u32,
        process_id: i32,
    },
    ThreadEnded {
        thread_id: u32,
    },
    DiskIo {
        disk_number: u32,
        thread_id: u32,
        operation: DiskOperation,
        transfer_bytes: u64,
    },
    TraceLoss {
        events: u64,
        buffers: u64,
    },
}

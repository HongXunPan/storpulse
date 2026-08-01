use std::collections::VecDeque;

use crate::DiagnosticEvent;

pub const SERVICE_EVENT_RING_CAPACITY: usize = 32;

#[derive(Debug)]
pub struct DiagnosticEventRing {
    capacity: usize,
    events: VecDeque<DiagnosticEvent>,
}

impl DiagnosticEventRing {
    pub fn service_default() -> Self {
        Self::with_capacity(SERVICE_EVENT_RING_CAPACITY)
    }

    pub fn with_capacity(capacity: usize) -> Self {
        assert!(capacity > 0, "诊断事件环容量必须大于零");
        Self {
            capacity,
            events: VecDeque::with_capacity(capacity),
        }
    }

    pub fn push(&mut self, event: DiagnosticEvent) {
        if self.events.len() == self.capacity {
            self.events.pop_front();
        }
        self.events.push_back(event);
    }

    pub fn len(&self) -> usize {
        self.events.len()
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    pub fn latest(&self) -> Option<&DiagnosticEvent> {
        self.events.back()
    }

    pub fn iter(&self) -> impl Iterator<Item = &DiagnosticEvent> {
        self.events.iter()
    }
}

impl Default for DiagnosticEventRing {
    fn default() -> Self {
        Self::service_default()
    }
}

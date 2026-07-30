use std::collections::VecDeque;

use crate::{
    command::EngineConfig,
    counter::{CounterDelta, calculate_delta},
    model::{IoRate, ProcessIoSample, RealtimeProcess},
};

#[derive(Debug, Clone, Copy)]
struct RatePoint {
    captured_at_nanoseconds: u64,
    interval_nanoseconds: u64,
    read_bytes: u64,
    write_bytes: u64,
}

#[derive(Debug)]
pub(crate) struct ProcessState {
    read_bytes: u64,
    write_bytes: u64,
    captured_at_nanoseconds: u64,
    run_read_bytes: u64,
    run_write_bytes: u64,
    history: VecDeque<RatePoint>,
    active_since_nanoseconds: Option<u64>,
}

#[derive(Debug)]
pub(crate) struct ProcessFrame {
    pub output: RealtimeProcess,
    pub delta: Option<CounterDelta>,
}

impl ProcessState {
    pub fn new(sample: &ProcessIoSample, captured_at_nanoseconds: u64) -> Self {
        Self {
            read_bytes: sample.read_bytes,
            write_bytes: sample.write_bytes,
            captured_at_nanoseconds,
            run_read_bytes: 0,
            run_write_bytes: 0,
            history: VecDeque::new(),
            active_since_nanoseconds: None,
        }
    }

    pub fn update(
        &mut self,
        sample: &ProcessIoSample,
        captured_at_nanoseconds: u64,
        config: &EngineConfig,
    ) -> ProcessFrame {
        let interval = captured_at_nanoseconds.saturating_sub(self.captured_at_nanoseconds);
        let delta = calculate_delta(
            self.read_bytes,
            self.write_bytes,
            sample.read_bytes,
            sample.write_bytes,
            interval,
        );

        if let Some(delta) = delta {
            self.run_read_bytes = self.run_read_bytes.saturating_add(delta.read_bytes);
            self.run_write_bytes = self.run_write_bytes.saturating_add(delta.write_bytes);
            self.history.push_back(RatePoint {
                captured_at_nanoseconds,
                interval_nanoseconds: interval,
                read_bytes: delta.read_bytes,
                write_bytes: delta.write_bytes,
            });
            if delta.read_bytes > 0 || delta.write_bytes > 0 {
                self.active_since_nanoseconds
                    .get_or_insert(self.captured_at_nanoseconds);
            } else {
                self.active_since_nanoseconds = None;
            }
        } else {
            self.active_since_nanoseconds = None;
        }

        self.read_bytes = sample.read_bytes;
        self.write_bytes = sample.write_bytes;
        self.captured_at_nanoseconds = captured_at_nanoseconds;
        prune_history(&mut self.history, captured_at_nanoseconds, config);

        ProcessFrame {
            output: RealtimeProcess {
                identity: sample.identity.clone(),
                parent_pid: sample.parent_pid,
                executable_name: sample.executable_name.clone(),
                application_id: sample.normalized_application_id(),
                application_name: sample.display_name(),
                is_helper: sample.is_helper,
                launched_by_application_id: sample.launched_by_application_id.clone(),
                current: delta.map(|value| value.rate),
                average_last_minute: average_rate(&self.history),
                run_read_bytes: self.run_read_bytes,
                run_write_bytes: self.run_write_bytes,
                continuous_io_duration_milliseconds: self
                    .active_since_nanoseconds
                    .map(|started| captured_at_nanoseconds.saturating_sub(started) / 1_000_000)
                    .unwrap_or(0),
                physical_footprint_bytes: sample.physical_footprint_bytes,
            },
            delta,
        }
    }
}

fn prune_history(
    history: &mut VecDeque<RatePoint>,
    captured_at_nanoseconds: u64,
    config: &EngineConfig,
) {
    while history.front().is_some_and(|point| {
        captured_at_nanoseconds.saturating_sub(point.captured_at_nanoseconds)
            > config.history_window_nanoseconds
    }) || history.len() > config.maximum_history_points
    {
        history.pop_front();
    }
}

fn average_rate(history: &VecDeque<RatePoint>) -> Option<IoRate> {
    let interval: u64 = history.iter().map(|point| point.interval_nanoseconds).sum();
    if interval == 0 {
        return None;
    }
    let read: u64 = history.iter().map(|point| point.read_bytes).sum();
    let write: u64 = history.iter().map(|point| point.write_bytes).sum();
    let seconds = interval as f64 / 1_000_000_000.0;
    Some(IoRate {
        read_bytes_per_second: read as f64 / seconds,
        write_bytes_per_second: write as f64 / seconds,
    })
}

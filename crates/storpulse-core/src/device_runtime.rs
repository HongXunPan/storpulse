use crate::{
    counter::{CounterDelta, calculate_delta},
    model::{DeviceIoSample, RealtimeDevice},
};

#[derive(Debug)]
pub(crate) struct DeviceState {
    read_bytes: u64,
    write_bytes: u64,
    captured_at_nanoseconds: u64,
    run_read_bytes: u64,
    run_write_bytes: u64,
}

impl DeviceState {
    pub fn new(sample: &DeviceIoSample, captured_at_nanoseconds: u64) -> Self {
        Self {
            read_bytes: sample.read_bytes,
            write_bytes: sample.write_bytes,
            captured_at_nanoseconds,
            run_read_bytes: 0,
            run_write_bytes: 0,
        }
    }

    pub fn update(
        &mut self,
        sample: &DeviceIoSample,
        captured_at_nanoseconds: u64,
    ) -> (RealtimeDevice, Option<CounterDelta>) {
        let delta = calculate_delta(
            self.read_bytes,
            self.write_bytes,
            sample.read_bytes,
            sample.write_bytes,
            captured_at_nanoseconds.saturating_sub(self.captured_at_nanoseconds),
        );
        if let Some(delta) = delta {
            self.run_read_bytes = self.run_read_bytes.saturating_add(delta.read_bytes);
            self.run_write_bytes = self.run_write_bytes.saturating_add(delta.write_bytes);
        }
        self.read_bytes = sample.read_bytes;
        self.write_bytes = sample.write_bytes;
        self.captured_at_nanoseconds = captured_at_nanoseconds;

        (
            RealtimeDevice {
                registry_entry_id: sample.registry_entry_id,
                current: delta.map(|value| value.rate),
                run_read_bytes: self.run_read_bytes,
                run_write_bytes: self.run_write_bytes,
            },
            delta,
        )
    }
}

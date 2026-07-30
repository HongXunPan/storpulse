use crate::model::IoRate;

#[derive(Debug, Clone, Copy)]
pub(crate) struct CounterDelta {
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub rate: IoRate,
}

pub(crate) fn calculate_delta(
    previous_read: u64,
    previous_write: u64,
    current_read: u64,
    current_write: u64,
    interval_nanoseconds: u64,
) -> Option<CounterDelta> {
    if interval_nanoseconds == 0 || current_read < previous_read || current_write < previous_write {
        return None;
    }

    let read_bytes = current_read - previous_read;
    let write_bytes = current_write - previous_write;
    let seconds = interval_nanoseconds as f64 / 1_000_000_000.0;
    Some(CounterDelta {
        read_bytes,
        write_bytes,
        rate: IoRate {
            read_bytes_per_second: read_bytes as f64 / seconds,
            write_bytes_per_second: write_bytes as f64 / seconds,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::calculate_delta;

    #[test]
    fn counter_reset_does_not_generate_negative_rate() {
        assert!(calculate_delta(100, 200, 10, 20, 1_000_000_000).is_none());
    }

    #[test]
    fn valid_delta_uses_monotonic_interval() {
        let delta = calculate_delta(100, 200, 300, 500, 2_000_000_000).unwrap();
        assert_eq!(delta.read_bytes, 200);
        assert_eq!(delta.write_bytes, 300);
        assert_eq!(delta.rate.read_bytes_per_second, 100.0);
        assert_eq!(delta.rate.write_bytes_per_second, 150.0);
    }
}

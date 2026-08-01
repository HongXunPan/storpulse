use windows_sys::Win32::System::SystemInformation::GetTickCount64;
use windows_sys::Win32::System::WindowsProgramming::QueryUnbiasedInterruptTime;

use super::ClientError;

#[derive(Debug, Clone, Copy)]
struct ClockSample {
    tick_count_milliseconds: u64,
    unbiased_time_100_nanoseconds: u64,
}

pub(super) struct SuspendDetector {
    previous: ClockSample,
}

pub(super) struct SleepObservation {
    pub(super) tick_count_milliseconds: u64,
    pub(super) estimated_sleep_milliseconds: u64,
}

impl SuspendDetector {
    pub(super) fn new() -> Result<Self, ClientError> {
        Ok(Self {
            previous: sample_clock()?,
        })
    }

    pub(super) fn baseline_tick_count_milliseconds(&self) -> u64 {
        self.previous.tick_count_milliseconds
    }

    pub(super) fn observe(&mut self) -> Result<SleepObservation, ClientError> {
        let sample = sample_clock()?;
        let estimated_sleep_milliseconds = estimate_sleep_milliseconds(self.previous, sample);
        self.previous = sample;
        Ok(SleepObservation {
            tick_count_milliseconds: sample.tick_count_milliseconds,
            estimated_sleep_milliseconds,
        })
    }
}

fn sample_clock() -> Result<ClockSample, ClientError> {
    let mut unbiased_time_100_nanoseconds = 0_u64;
    // SAFETY：输出指针指向当前栈上的有效 u64，系统调用不会保留该指针。
    let succeeded = unsafe { QueryUnbiasedInterruptTime(&mut unbiased_time_100_nanoseconds) };
    if succeeded == 0 {
        return Err(ClientError::new(
            "sleep_resume",
            "unbiased_clock_query_failed",
            None,
        ));
    }
    // SAFETY：GetTickCount64 无参数且无失败状态。
    let tick_count_milliseconds = unsafe { GetTickCount64() };
    Ok(ClockSample {
        tick_count_milliseconds,
        unbiased_time_100_nanoseconds,
    })
}

fn estimate_sleep_milliseconds(previous: ClockSample, current: ClockSample) -> u64 {
    let elapsed_tick = current
        .tick_count_milliseconds
        .saturating_sub(previous.tick_count_milliseconds);
    let elapsed_unbiased = current
        .unbiased_time_100_nanoseconds
        .saturating_sub(previous.unbiased_time_100_nanoseconds)
        / 10_000;
    elapsed_tick.saturating_sub(elapsed_unbiased)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimates_non_working_interval_from_clock_difference() {
        let previous = ClockSample {
            tick_count_milliseconds: 10_000,
            unbiased_time_100_nanoseconds: 100_000_000,
        };
        let current = ClockSample {
            tick_count_milliseconds: 25_000,
            unbiased_time_100_nanoseconds: 130_000_000,
        };

        assert_eq!(estimate_sleep_milliseconds(previous, current), 12_000);
    }

    #[test]
    fn small_clock_rounding_difference_does_not_underflow() {
        let previous = ClockSample {
            tick_count_milliseconds: 10_000,
            unbiased_time_100_nanoseconds: 100_000_000,
        };
        let current = ClockSample {
            tick_count_milliseconds: 10_999,
            unbiased_time_100_nanoseconds: 110_000_000,
        };

        assert_eq!(estimate_sleep_milliseconds(previous, current), 0);
    }
}

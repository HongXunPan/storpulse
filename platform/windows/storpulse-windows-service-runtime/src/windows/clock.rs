use std::time::Instant;

use windows_sys::Win32::Foundation::SYSTEMTIME;
use windows_sys::Win32::System::SystemInformation::GetSystemTime;

pub(super) struct SessionClock {
    started: Instant,
    last_monotonic_nanoseconds: u64,
}

impl SessionClock {
    pub(super) fn start() -> Self {
        Self {
            started: Instant::now(),
            last_monotonic_nanoseconds: 0,
        }
    }

    pub(super) fn capture(&mut self) -> (String, u64) {
        let elapsed = self.started.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64;
        let monotonic_nanoseconds = elapsed.max(self.last_monotonic_nanoseconds.saturating_add(1));
        self.last_monotonic_nanoseconds = monotonic_nanoseconds;
        (utc_timestamp(), monotonic_nanoseconds)
    }
}

fn utc_timestamp() -> String {
    let mut value = SYSTEMTIME::default();
    // SAFETY：GetSystemTime 只写入固定大小的 SYSTEMTIME 输出缓冲区。
    unsafe { GetSystemTime(&mut value) };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        value.wYear,
        value.wMonth,
        value.wDay,
        value.wHour,
        value.wMinute,
        value.wSecond,
        value.wMilliseconds
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_returns_utc_shape_and_increasing_monotonic_time() {
        let mut clock = SessionClock::start();
        let (timestamp, first) = clock.capture();
        let (_, second) = clock.capture();

        assert_eq!(timestamp.len(), 24);
        assert!(timestamp.ends_with('Z'));
        assert!(second > first);
    }
}

use std::collections::HashMap;

use crate::model::{
    ApplicationContribution, Completeness, IoRate, ObservationSession, ObservationSessionProgress,
};

#[derive(Debug, Clone)]
pub(crate) struct FrameContribution {
    pub application_id: String,
    pub display_name: String,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub current: Option<IoRate>,
}

#[derive(Debug)]
struct ActiveSession {
    session_id: String,
    started_at: String,
    started_monotonic_nanoseconds: u64,
    read_bytes: u64,
    write_bytes: u64,
    peak: IoRate,
    contributions: HashMap<String, ApplicationContribution>,
    completeness: Completeness,
}

#[derive(Debug, Default)]
pub(crate) struct SessionTracker {
    active: Option<ActiveSession>,
}

impl SessionTracker {
    pub fn start(
        &mut self,
        session_id: String,
        started_at: String,
        monotonic_nanoseconds: u64,
        completeness: Completeness,
    ) -> Result<(), &'static str> {
        if self.active.is_some() {
            return Err("已经存在进行中的观察会话");
        }
        if session_id.trim().is_empty() {
            return Err("观察会话标识不能为空");
        }
        self.active = Some(ActiveSession {
            session_id,
            started_at,
            started_monotonic_nanoseconds: monotonic_nanoseconds,
            read_bytes: 0,
            write_bytes: 0,
            peak: IoRate::default(),
            contributions: HashMap::new(),
            completeness,
        });
        Ok(())
    }

    pub fn update(
        &mut self,
        device_delta: (u64, u64),
        device_rate: Option<IoRate>,
        applications: &[FrameContribution],
        completeness: Completeness,
    ) {
        let Some(active) = self.active.as_mut() else {
            return;
        };

        let application_read: u64 = applications.iter().map(|item| item.read_bytes).sum();
        let application_write: u64 = applications.iter().map(|item| item.write_bytes).sum();
        let selected_delta = if device_rate.is_some() {
            device_delta
        } else {
            (application_read, application_write)
        };
        active.read_bytes = active.read_bytes.saturating_add(selected_delta.0);
        active.write_bytes = active.write_bytes.saturating_add(selected_delta.1);

        let fallback_rate = IoRate {
            read_bytes_per_second: applications
                .iter()
                .filter_map(|item| item.current)
                .map(|rate| rate.read_bytes_per_second)
                .sum(),
            write_bytes_per_second: applications
                .iter()
                .filter_map(|item| item.current)
                .map(|rate| rate.write_bytes_per_second)
                .sum(),
        };
        let rate = device_rate.unwrap_or(fallback_rate);
        active.peak.read_bytes_per_second = active
            .peak
            .read_bytes_per_second
            .max(rate.read_bytes_per_second);
        active.peak.write_bytes_per_second = active
            .peak
            .write_bytes_per_second
            .max(rate.write_bytes_per_second);
        active.completeness = less_complete(active.completeness, completeness);

        for application in applications {
            let contribution = active
                .contributions
                .entry(application.application_id.clone())
                .or_insert_with(|| ApplicationContribution {
                    application_id: application.application_id.clone(),
                    display_name: application.display_name.clone(),
                    read_bytes: 0,
                    write_bytes: 0,
                });
            contribution.read_bytes = contribution
                .read_bytes
                .saturating_add(application.read_bytes);
            contribution.write_bytes = contribution
                .write_bytes
                .saturating_add(application.write_bytes);
        }
    }

    pub fn progress(&self, monotonic_nanoseconds: u64) -> Option<ObservationSessionProgress> {
        let active = self.active.as_ref()?;
        Some(ObservationSessionProgress {
            session_id: active.session_id.clone(),
            started_at: active.started_at.clone(),
            duration_milliseconds: monotonic_nanoseconds
                .saturating_sub(active.started_monotonic_nanoseconds)
                / 1_000_000,
            read_bytes: active.read_bytes,
            write_bytes: active.write_bytes,
            peak_read_bytes_per_second: active.peak.read_bytes_per_second,
            peak_write_bytes_per_second: active.peak.write_bytes_per_second,
        })
    }

    pub fn stop(
        &mut self,
        ended_at: String,
        monotonic_nanoseconds: u64,
    ) -> Result<ObservationSession, &'static str> {
        let active = self.active.take().ok_or("没有进行中的观察会话")?;
        let mut top_applications: Vec<_> = active.contributions.into_values().collect();
        top_applications.sort_by_key(|item| {
            std::cmp::Reverse(item.read_bytes.saturating_add(item.write_bytes))
        });
        top_applications.truncate(10);

        Ok(ObservationSession {
            session_id: active.session_id,
            started_at: active.started_at,
            ended_at,
            duration_milliseconds: monotonic_nanoseconds
                .saturating_sub(active.started_monotonic_nanoseconds)
                / 1_000_000,
            read_bytes: active.read_bytes,
            write_bytes: active.write_bytes,
            peak: active.peak,
            top_applications,
            completeness: active.completeness,
        })
    }
}

fn less_complete(left: Completeness, right: Completeness) -> Completeness {
    use Completeness::{Complete, Partial, Restricted, Unsupported};
    match (left, right) {
        (Unsupported, _) | (_, Unsupported) => Unsupported,
        (Restricted, _) | (_, Restricted) => Restricted,
        (Partial, _) | (_, Partial) => Partial,
        (Complete, Complete) => Complete,
    }
}

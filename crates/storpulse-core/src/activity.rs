use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::{
    model::{ActivitySummary, IoRate},
    session_tracker::FrameContribution,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityPolicy {
    pub enabled: bool,
    pub read_threshold_bytes_per_second: f64,
    pub write_threshold_bytes_per_second: f64,
    pub minimum_duration_milliseconds: u64,
}

impl Default for ActivityPolicy {
    fn default() -> Self {
        Self {
            enabled: false,
            read_threshold_bytes_per_second: 0.0,
            write_threshold_bytes_per_second: 0.0,
            minimum_duration_milliseconds: 0,
        }
    }
}

#[derive(Debug)]
struct ActiveActivity {
    display_name: String,
    started_at: String,
    started_monotonic_nanoseconds: u64,
    read_bytes: u64,
    write_bytes: u64,
    peak: IoRate,
}

#[derive(Debug, Default)]
pub(crate) struct ActivityTracker {
    policy: ActivityPolicy,
    active: HashMap<String, ActiveActivity>,
}

impl ActivityTracker {
    pub fn set_policy(&mut self, policy: ActivityPolicy) -> Result<(), &'static str> {
        if policy.enabled
            && policy.read_threshold_bytes_per_second <= 0.0
            && policy.write_threshold_bytes_per_second <= 0.0
        {
            return Err("启用活动识别时至少需要一个正数阈值");
        }
        self.policy = policy;
        if !self.policy.enabled {
            self.active.clear();
        }
        Ok(())
    }

    pub fn update(
        &mut self,
        captured_at: &str,
        monotonic_nanoseconds: u64,
        applications: &[FrameContribution],
    ) -> Vec<ActivitySummary> {
        if !self.policy.enabled {
            return Vec::new();
        }

        let mut completed = Vec::new();
        let mut currently_above = Vec::new();
        for application in applications {
            let Some(rate) = application.current else {
                continue;
            };
            let is_above = rate.read_bytes_per_second
                >= self.policy.read_threshold_bytes_per_second
                || rate.write_bytes_per_second >= self.policy.write_threshold_bytes_per_second;
            if !is_above {
                continue;
            }
            currently_above.push(application.application_id.clone());
            let active = self
                .active
                .entry(application.application_id.clone())
                .or_insert_with(|| ActiveActivity {
                    display_name: application.display_name.clone(),
                    started_at: captured_at.to_owned(),
                    started_monotonic_nanoseconds: monotonic_nanoseconds,
                    read_bytes: 0,
                    write_bytes: 0,
                    peak: IoRate::default(),
                });
            active.read_bytes = active.read_bytes.saturating_add(application.read_bytes);
            active.write_bytes = active.write_bytes.saturating_add(application.write_bytes);
            active.peak.read_bytes_per_second = active
                .peak
                .read_bytes_per_second
                .max(rate.read_bytes_per_second);
            active.peak.write_bytes_per_second = active
                .peak
                .write_bytes_per_second
                .max(rate.write_bytes_per_second);
        }

        let ended: Vec<_> = self
            .active
            .keys()
            .filter(|id| !currently_above.contains(id))
            .cloned()
            .collect();
        for application_id in ended {
            let Some(active) = self.active.remove(&application_id) else {
                continue;
            };
            let duration_milliseconds = monotonic_nanoseconds
                .saturating_sub(active.started_monotonic_nanoseconds)
                / 1_000_000;
            if duration_milliseconds < self.policy.minimum_duration_milliseconds {
                continue;
            }
            completed.push(ActivitySummary {
                application_id,
                display_name: active.display_name,
                started_at: active.started_at,
                ended_at: captured_at.to_owned(),
                duration_milliseconds,
                read_bytes: active.read_bytes,
                write_bytes: active.write_bytes,
                peak: active.peak,
            });
        }
        completed
    }
}

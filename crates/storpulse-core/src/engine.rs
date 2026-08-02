use std::collections::{HashMap, HashSet};

use crate::{
    activity::ActivityTracker,
    aggregation::aggregate_applications,
    command::{EngineCommand, EngineCommandResult, EngineConfig, EngineError},
    counter::CounterDelta,
    device_runtime::DeviceState,
    model::{
        ActivitySummary, Completeness, Freshness, IoRate, ProcessIdentity, RawSnapshot,
        RealtimeDevice, RealtimeProcess, RealtimeSnapshot, RealtimeSummary,
        SNAPSHOT_SCHEMA_VERSION,
    },
    process_runtime::ProcessState,
    session_tracker::SessionTracker,
};

#[derive(Debug)]
pub struct Engine {
    config: EngineConfig,
    process_states: HashMap<ProcessIdentity, ProcessState>,
    device_states: HashMap<String, DeviceState>,
    session_tracker: SessionTracker,
    activity_tracker: ActivityTracker,
    completed_activities: Vec<ActivitySummary>,
    last_snapshot: Option<RealtimeSnapshot>,
}

impl Engine {
    pub fn new(config: EngineConfig) -> Self {
        Self {
            config,
            process_states: HashMap::new(),
            device_states: HashMap::new(),
            session_tracker: SessionTracker::default(),
            activity_tracker: ActivityTracker::default(),
            completed_activities: Vec::new(),
            last_snapshot: None,
        }
    }

    pub fn ingest(&mut self, raw: RawSnapshot) -> Result<RealtimeSnapshot, EngineError> {
        self.validate(&raw)?;
        let is_fresh = raw.freshness == Freshness::Fresh;
        let (processes, process_deltas) = self.process_frames(&raw, is_fresh);
        let (devices, device_delta, device_rate) = self.device_frames(&raw, is_fresh);
        let (applications, contributions) = aggregate_applications(&processes, &process_deltas);

        self.session_tracker
            .update(device_delta, device_rate, &contributions, raw.completeness);
        self.completed_activities
            .extend(self.activity_tracker.update(
                &raw.captured_at,
                raw.monotonic_nanoseconds,
                &contributions,
            ));

        let snapshot = RealtimeSnapshot {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            captured_at: raw.captured_at.clone(),
            monotonic_nanoseconds: raw.monotonic_nanoseconds,
            metric_source: raw.metric_source,
            metric_scope: raw.metric_scope,
            freshness: raw.freshness,
            completeness: raw.completeness,
            devices,
            applications,
            processes,
            summary: RealtimeSummary {
                discovered_processes: raw.summary.discovered_processes,
                readable_processes: raw.summary.readable_processes,
                restricted_processes: raw.summary.restricted_processes,
                exited_processes: raw.summary.exited_processes,
                device_count: raw.summary.device_count,
                collection_duration_nanoseconds: raw.summary.collection_duration_nanoseconds,
                last_successful_sample_at: raw.captured_at,
                unmapped_disk_events: raw.summary.unmapped_disk_events,
                events_lost: raw.summary.events_lost,
                buffers_lost: raw.summary.buffers_lost,
            },
            active_observation_session: self.session_tracker.progress(raw.monotonic_nanoseconds),
        };
        self.last_snapshot = Some(snapshot.clone());
        Ok(snapshot)
    }

    pub fn snapshot_at(&self, monotonic_nanoseconds: u64) -> Result<RealtimeSnapshot, EngineError> {
        let mut snapshot = self.last_snapshot.clone().ok_or(EngineError::NoSnapshot)?;
        if monotonic_nanoseconds.saturating_sub(snapshot.monotonic_nanoseconds)
            > self.config.stale_after_nanoseconds
        {
            snapshot.freshness = Freshness::Stale;
            snapshot
                .devices
                .iter_mut()
                .for_each(|item| item.current = None);
            snapshot
                .applications
                .iter_mut()
                .for_each(|item| item.current = None);
            snapshot
                .processes
                .iter_mut()
                .for_each(|item| item.current = None);
        }
        Ok(snapshot)
    }

    pub fn execute(&mut self, command: EngineCommand) -> Result<EngineCommandResult, EngineError> {
        match command {
            EngineCommand::StartObservation {
                session_id,
                started_at,
                monotonic_nanoseconds,
            } => {
                let completeness = self
                    .last_snapshot
                    .as_ref()
                    .map(|snapshot| snapshot.completeness)
                    .unwrap_or(Completeness::Partial);
                self.session_tracker
                    .start(session_id, started_at, monotonic_nanoseconds, completeness)
                    .map_err(invalid_command)?;
                Ok(EngineCommandResult::Accepted)
            }
            EngineCommand::StopObservation {
                ended_at,
                monotonic_nanoseconds,
            } => {
                let session = self
                    .session_tracker
                    .stop(ended_at, monotonic_nanoseconds)
                    .map_err(invalid_command)?;
                Ok(EngineCommandResult::ObservationStopped { session })
            }
            EngineCommand::ConfigureActivity { policy } => {
                self.activity_tracker
                    .set_policy(policy)
                    .map_err(invalid_command)?;
                Ok(EngineCommandResult::Accepted)
            }
            EngineCommand::DrainCompletedActivities => {
                let activities = std::mem::take(&mut self.completed_activities);
                Ok(EngineCommandResult::CompletedActivities { activities })
            }
        }
    }

    fn validate(&self, raw: &RawSnapshot) -> Result<(), EngineError> {
        if raw.schema_version != SNAPSHOT_SCHEMA_VERSION {
            return Err(EngineError::UnsupportedSchema(raw.schema_version));
        }
        if self
            .last_snapshot
            .as_ref()
            .is_some_and(|previous| raw.monotonic_nanoseconds <= previous.monotonic_nanoseconds)
        {
            return Err(EngineError::NonMonotonicSample);
        }
        Ok(())
    }

    fn process_frames(
        &mut self,
        raw: &RawSnapshot,
        is_fresh: bool,
    ) -> (
        Vec<RealtimeProcess>,
        HashMap<ProcessIdentity, Option<CounterDelta>>,
    ) {
        let mut outputs = Vec::with_capacity(raw.processes.len());
        let mut deltas = HashMap::new();
        let mut current_identities = HashSet::new();

        for sample in &raw.processes {
            current_identities.insert(sample.identity.clone());
            let state = self
                .process_states
                .entry(sample.identity.clone())
                .or_insert_with(|| ProcessState::new(sample, raw.monotonic_nanoseconds));
            let mut frame = state.update(sample, raw.monotonic_nanoseconds, &self.config);
            if !is_fresh {
                frame.output.current = None;
                frame.delta = None;
            }
            deltas.insert(sample.identity.clone(), frame.delta);
            outputs.push(frame.output);
        }
        self.process_states
            .retain(|identity, _| current_identities.contains(identity));
        outputs.sort_by(|left, right| {
            process_activity(right)
                .total_cmp(&process_activity(left))
                .then_with(|| left.identity.pid.cmp(&right.identity.pid))
        });
        (outputs, deltas)
    }

    fn device_frames(
        &mut self,
        raw: &RawSnapshot,
        is_fresh: bool,
    ) -> (Vec<RealtimeDevice>, (u64, u64), Option<IoRate>) {
        let mut outputs = Vec::with_capacity(raw.devices.len());
        let mut current_ids = HashSet::new();
        let mut total_delta = (0_u64, 0_u64);
        let mut total_rate = IoRate::default();
        let mut has_rate = false;

        for sample in &raw.devices {
            current_ids.insert(sample.device_id.clone());
            let state = self
                .device_states
                .entry(sample.device_id.clone())
                .or_insert_with(|| DeviceState::new(sample, raw.monotonic_nanoseconds));
            let (mut output, delta) = state.update(sample, raw.monotonic_nanoseconds);
            if let Some(delta) = delta.filter(|_| is_fresh) {
                total_delta.0 = total_delta.0.saturating_add(delta.read_bytes);
                total_delta.1 = total_delta.1.saturating_add(delta.write_bytes);
                total_rate.read_bytes_per_second += delta.rate.read_bytes_per_second;
                total_rate.write_bytes_per_second += delta.rate.write_bytes_per_second;
                has_rate = true;
            } else if !is_fresh {
                output.current = None;
            }
            outputs.push(output);
        }
        self.device_states
            .retain(|identity, _| current_ids.contains(identity));
        outputs.sort_by(|left, right| left.device_id.cmp(&right.device_id));
        (outputs, total_delta, has_rate.then_some(total_rate))
    }
}

impl Default for Engine {
    fn default() -> Self {
        Self::new(EngineConfig::default())
    }
}

fn invalid_command(message: &str) -> EngineError {
    EngineError::InvalidCommand(message.to_owned())
}

fn process_activity(process: &RealtimeProcess) -> f64 {
    process
        .current
        .map(|rate| rate.read_bytes_per_second + rate.write_bytes_per_second)
        .unwrap_or(0.0)
}

use std::collections::{BTreeMap, HashMap};

use crate::{
    counter::CounterDelta,
    model::{IoRate, ProcessIdentity, RealtimeApplication, RealtimeProcess},
    session_tracker::FrameContribution,
};

#[derive(Debug)]
struct ApplicationAccumulator {
    display_name: String,
    process_count: usize,
    helper_count: usize,
    current: IoRate,
    current_count: usize,
    average: IoRate,
    average_count: usize,
    run_read_bytes: u64,
    run_write_bytes: u64,
    read_delta: u64,
    write_delta: u64,
    continuous_io_duration_milliseconds: u64,
    process_identities: Vec<ProcessIdentity>,
}

pub(crate) fn aggregate_applications(
    processes: &[RealtimeProcess],
    deltas: &HashMap<ProcessIdentity, Option<CounterDelta>>,
) -> (Vec<RealtimeApplication>, Vec<FrameContribution>) {
    let mut accumulators: BTreeMap<String, ApplicationAccumulator> = BTreeMap::new();
    for process in processes {
        let accumulator = accumulators
            .entry(process.application_id.clone())
            .or_insert_with(|| ApplicationAccumulator {
                display_name: process.application_name.clone(),
                process_count: 0,
                helper_count: 0,
                current: IoRate::default(),
                current_count: 0,
                average: IoRate::default(),
                average_count: 0,
                run_read_bytes: 0,
                run_write_bytes: 0,
                read_delta: 0,
                write_delta: 0,
                continuous_io_duration_milliseconds: 0,
                process_identities: Vec::new(),
            });
        accumulator.process_count += 1;
        accumulator.helper_count += usize::from(process.is_helper);
        accumulator.run_read_bytes = accumulator
            .run_read_bytes
            .saturating_add(process.run_read_bytes);
        accumulator.run_write_bytes = accumulator
            .run_write_bytes
            .saturating_add(process.run_write_bytes);
        accumulator.continuous_io_duration_milliseconds = accumulator
            .continuous_io_duration_milliseconds
            .max(process.continuous_io_duration_milliseconds);
        accumulator
            .process_identities
            .push(process.identity.clone());
        if let Some(rate) = process.current {
            accumulator.current.read_bytes_per_second += rate.read_bytes_per_second;
            accumulator.current.write_bytes_per_second += rate.write_bytes_per_second;
            accumulator.current_count += 1;
        }
        if let Some(rate) = process.average_last_minute {
            accumulator.average.read_bytes_per_second += rate.read_bytes_per_second;
            accumulator.average.write_bytes_per_second += rate.write_bytes_per_second;
            accumulator.average_count += 1;
        }
        if let Some(Some(delta)) = deltas.get(&process.identity) {
            accumulator.read_delta = accumulator.read_delta.saturating_add(delta.read_bytes);
            accumulator.write_delta = accumulator.write_delta.saturating_add(delta.write_bytes);
        }
    }

    let mut contributions = Vec::with_capacity(accumulators.len());
    let mut applications: Vec<_> = accumulators
        .into_iter()
        .map(|(application_id, accumulator)| {
            let current = (accumulator.current_count > 0).then_some(accumulator.current);
            contributions.push(FrameContribution {
                application_id: application_id.clone(),
                display_name: accumulator.display_name.clone(),
                read_bytes: accumulator.read_delta,
                write_bytes: accumulator.write_delta,
                current,
            });
            RealtimeApplication {
                application_id,
                display_name: accumulator.display_name,
                process_count: accumulator.process_count,
                helper_count: accumulator.helper_count,
                current,
                average_last_minute: (accumulator.average_count > 0).then_some(accumulator.average),
                run_read_bytes: accumulator.run_read_bytes,
                run_write_bytes: accumulator.run_write_bytes,
                continuous_io_duration_milliseconds: accumulator
                    .continuous_io_duration_milliseconds,
                process_identities: accumulator.process_identities,
            }
        })
        .collect();
    applications.sort_by(|left, right| {
        activity(right)
            .total_cmp(&activity(left))
            .then_with(|| left.application_id.cmp(&right.application_id))
    });
    (applications, contributions)
}

fn activity(application: &RealtimeApplication) -> f64 {
    application
        .current
        .map(|rate| rate.read_bytes_per_second + rate.write_bytes_per_second)
        .unwrap_or(0.0)
}

use crate::model::{Stage0Report, TimelineEvent};
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::Path;

pub fn write_reports(
    output_directory: &Path,
    report: &Stage0Report,
    timeline: &[TimelineEvent],
) -> Result<(), String> {
    fs::create_dir_all(output_directory).map_err(|_| "无法创建诊断输出目录".to_string())?;
    write_json(output_directory, "summary.json", report)?;
    write_json(output_directory, "errors.json", &report.errors)?;
    write_json(output_directory, "workload.json", &report.workload)?;
    write_ndjson(output_directory, "timeline.ndjson", timeline)?;
    Ok(())
}

fn write_json<T: serde::Serialize>(
    directory: &Path,
    file_name: &str,
    value: &T,
) -> Result<(), String> {
    let temporary_name = format!(".{file_name}.writing");
    let temporary_path = directory.join(temporary_name);
    let final_path = directory.join(file_name);
    let data = serde_json::to_vec_pretty(value).map_err(|_| "诊断 JSON 编码失败".to_string())?;
    fs::write(&temporary_path, data).map_err(|_| "诊断 JSON 写入失败".to_string())?;
    fs::rename(&temporary_path, &final_path).map_err(|_| "诊断 JSON 原子替换失败".to_string())?;
    Ok(())
}

fn write_ndjson(directory: &Path, file_name: &str, events: &[TimelineEvent]) -> Result<(), String> {
    let temporary_path = directory.join(format!(".{file_name}.writing"));
    let final_path = directory.join(file_name);
    let file = File::create(&temporary_path).map_err(|_| "时间线日志创建失败".to_string())?;
    let mut writer = BufWriter::new(file);
    for event in events {
        serde_json::to_writer(&mut writer, event).map_err(|_| "时间线日志编码失败".to_string())?;
        writer
            .write_all(b"\n")
            .map_err(|_| "时间线日志写入失败".to_string())?;
    }
    writer
        .flush()
        .map_err(|_| "时间线日志刷新失败".to_string())?;
    fs::rename(&temporary_path, &final_path).map_err(|_| "时间线日志原子替换失败".to_string())?;
    Ok(())
}

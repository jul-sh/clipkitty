//! `clipkitty perf` — performance test orchestration.
//!
//! Owns both the Instruments trace capture flow and the trace analysis that
//! used to live in bash + Python helpers.

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};
use chrono::Local;
use roxmltree::Document;
use serde::Serialize;
use tempfile::TempDir;

use crate::cli::PerfArgs;
use crate::cmd::build;
use crate::model::{MacVariant, SideEffectLevel};
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

const APP_NAME: &str = "ClipKitty";
const BUNDLE_ID: &str = "com.eviljuliette.clipkitty";
const PERF_QUERY_DELAY_MS: u64 = 5_000;
const PERF_QUERIES: &[&str] = &[
    "function",
    "import",
    "return value",
    "error handling",
    "async await",
    "class struct",
    "for loop",
];
const DEFAULT_TYPING_DELAY_MS: u64 = 100;
const DEFAULT_IGNORE_FIRST_SECONDS: f64 = 3.0;

pub fn run(args: &PerfArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::LocalMutation;
    let repo = RepoRoot::discover(reporter)?;
    run_perf(&repo, args, dry_run, reporter)
}

fn run_perf(repo: &RepoRoot, args: &PerfArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let timestamp = Local::now().format("%Y%m%d_%H%M%S").to_string();
    let output_dir = repo.join("perf_traces");
    let trace_file = output_dir.join(format!("perf_{timestamp}.trace"));
    let log_file = output_dir.join(format!("typing_log_{timestamp}.txt"));
    let report_file = output_dir.join(format!("report_{timestamp}.json"));

    if dry_run {
        reporter.info(&format!("[dry-run] would run perf trace → {}", trace_file));
        reporter.info("[dry-run] would materialize generated sources and build Release app");
        reporter.info("[dry-run] would refresh the synthetic benchmark fixture");
        return Ok(());
    }

    fs::create_dir_all(output_dir.as_std_path())
        .with_context(|| format!("creating {output_dir}"))?;

    reporter.info("=== ClipKitty Performance Test ===");
    reporter.info("Scenario: typing");
    reporter.info("Template: Time Profiler");
    reporter.info(&format!("Output: {trace_file}"));

    reporter.info(">>> Building app (Release)...");
    build::generate(repo, false, reporter)?;
    build::stage_app(
        repo,
        &build::BuildAppRequest {
            variant: MacVariant::Release,
            version: None,
            build_number: None,
        },
        false,
        reporter,
    )?;

    let app_path = build::staged_app_path(repo, MacVariant::Release);
    if !app_path.as_std_path().is_dir() {
        return Err(anyhow!("app not found at {app_path}"));
    }

    ensure_perf_fixture(repo, reporter)?;
    setup_perf_database(repo, reporter)?;

    reporter.info(">>> Launching ClipKitty...");
    Runner::new(reporter, "open")
        .arg(app_path.as_std_path())
        .args(["--args", "--use-simulated-db"])
        .run()?;
    thread::sleep(Duration::from_secs(3));

    let pgrep = Runner::new(reporter, "pgrep")
        .arg("-x")
        .arg(APP_NAME)
        .capture_stderr()
        .output_status()?;
    if !pgrep.status.success() {
        return Err(anyhow!("ClipKitty failed to launch"));
    }
    let pid = String::from_utf8_lossy(&pgrep.stdout).trim().to_string();
    reporter.info(&format!("    App running (PID: {pid})"));

    reporter.info(&format!(
        ">>> Starting Instruments trace (template: {})...",
        "Time Profiler"
    ));
    reporter.trace_command(&format!(
        "xcrun xctrace record --template Time Profiler --attach {} --output {} --time-limit 120s",
        APP_NAME, trace_file
    ));
    let mut xctrace = Command::new("xcrun")
        .arg("xctrace")
        .arg("record")
        .arg("--template")
        .arg("Time Profiler")
        .arg("--attach")
        .arg(APP_NAME)
        .arg("--output")
        .arg(trace_file.as_std_path())
        .arg("--time-limit")
        .arg("120s")
        .spawn()
        .context("starting xctrace")?;
    reporter.info(&format!("    xctrace PID: {}", xctrace.id()));
    thread::sleep(Duration::from_secs(3));

    reporter.info(">>> Running typing simulation...");
    run_typing_scenario(&log_file, reporter)?;

    reporter.info(">>> Stopping trace...");
    thread::sleep(Duration::from_secs(2));
    let _ = Runner::new(reporter, "kill")
        .arg("-SIGINT")
        .arg(xctrace.id().to_string())
        .status();

    for _ in 0..30 {
        if xctrace.try_wait()?.is_some() {
            break;
        }
        thread::sleep(Duration::from_secs(1));
    }
    if xctrace.try_wait()?.is_none() {
        let _ = xctrace.kill();
        let _ = xctrace.wait();
    }

    reporter.info(">>> Terminating ClipKitty...");
    let _ = Runner::new(reporter, "pkill")
        .arg("-9")
        .arg(APP_NAME)
        .status();

    if !trace_file.as_std_path().exists() {
        return Err(anyhow!(
            "trace file not found after xctrace completed: {trace_file}"
        ));
    }
    reporter.info(&format!(">>> Trace saved: {trace_file}"));

    reporter.info(">>> Analyzing trace...");
    let report = analyze_trace(
        &trace_file,
        args.hang_threshold as f64,
        100.0,
        false,
        DEFAULT_IGNORE_FIRST_SECONDS * 1000.0,
        reporter,
    )?;
    fs::write(
        report_file.as_std_path(),
        format!("{}\n", serde_json::to_string_pretty(&report)?),
    )
    .with_context(|| format!("writing {report_file}"))?;
    print_report(&report, reporter);
    reporter.info(&format!("JSON report: {report_file}"));
    reporter.info(&format!("Simulation log: {log_file}"));

    if args.fail_on_hangs && !report.passed {
        return Err(anyhow!("performance test failed: hangs detected"));
    }

    reporter.success("Performance test complete.");
    Ok(())
}

fn ensure_perf_fixture(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let fixture_dir = repo.join("purr/generated/benchmarks");
    let fixture_db = fixture_dir.join("synthetic_clipboard.sqlite");
    let has_index = fs::read_dir(fixture_dir.as_std_path())
        .ok()
        .into_iter()
        .flat_map(|entries| entries.flatten())
        .any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("tantivy_index_")
        });

    if fixture_db.as_std_path().is_file() && has_index {
        reporter.info(">>> Using existing performance database and index");
        return Ok(());
    }

    reporter.info(">>> Generating performance test database and index...");
    let mut runner = Runner::new(reporter, "cargo")
        .args([
            "run",
            "--release",
            "-p",
            "purr",
            "--bin",
            "generate-perf-db",
        ])
        .cwd(repo.as_path());
    if locked_cargo() {
        runner = runner.arg("--locked");
    }
    runner.run()
}

fn setup_perf_database(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    reporter.info(">>> Setting up test database...");
    let fixture_dir = repo.join("purr/generated/benchmarks");
    let fixture_db = fixture_dir.join("synthetic_clipboard.sqlite");
    let app_support = app_support_dir()?;
    fs::create_dir_all(app_support.as_std_path())
        .with_context(|| format!("creating {app_support}"))?;

    let _ = Runner::new(reporter, "pkill")
        .arg("-9")
        .arg(APP_NAME)
        .status();
    thread::sleep(Duration::from_secs(1));

    remove_if_exists(&app_support.join("clipboard-screenshot.sqlite"))?;
    for entry in
        fs::read_dir(app_support.as_std_path()).with_context(|| format!("reading {app_support}"))?
    {
        let entry = entry?;
        let path = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
        if path
            .file_name()
            .is_some_and(|name| name.starts_with("tantivy_index_"))
        {
            remove_if_exists(&path)?;
        }
    }

    if fixture_db.as_std_path().is_file() {
        fs::copy(
            fixture_db.as_std_path(),
            app_support
                .join("clipboard-screenshot.sqlite")
                .as_std_path(),
        )
        .with_context(|| format!("copying {fixture_db} into {app_support}"))?;
    }

    for entry in
        fs::read_dir(fixture_dir.as_std_path()).with_context(|| format!("reading {fixture_dir}"))?
    {
        let entry = entry?;
        let path = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
        if path
            .file_name()
            .is_some_and(|name| name.starts_with("tantivy_index_"))
        {
            copy_dir_recursive(&path, &app_support.join(path.file_name().unwrap()))?;
        }
    }

    reporter.info("    Database and pre-built index copied to app container");
    Ok(())
}

fn app_support_dir() -> Result<Utf8PathBuf> {
    let home = env::var("HOME").context("HOME is not set")?;
    Ok(Utf8PathBuf::from(home).join(format!(
        "Library/Containers/{BUNDLE_ID}/Data/Library/Application Support/{APP_NAME}"
    )))
}

fn run_typing_scenario(log_file: &Utf8Path, reporter: &Reporter) -> Result<()> {
    let output = run_typing_simulation(DEFAULT_TYPING_DELAY_MS, PERF_QUERY_DELAY_MS, reporter)?;
    fs::write(log_file.as_std_path(), output).with_context(|| format!("writing {log_file}"))?;
    Ok(())
}

fn run_typing_simulation(
    keystroke_delay_ms: u64,
    query_delay_ms: u64,
    reporter: &Reporter,
) -> Result<Vec<u8>> {
    if !is_clipkitty_running(reporter)? {
        return Err(anyhow!("ClipKitty is not running"));
    }
    let query_list = PERF_QUERIES
        .iter()
        .map(|query| format!("\"{}\"", query.replace('"', "\\\"")))
        .collect::<Vec<_>>()
        .join(", ");
    let script = format!(
        r#"
tell application "System Events"
    tell application process "ClipKitty"
        set frontmost to true
    end tell

    delay 0.5
    set queryList to {{{query_list}}}

    repeat with queryValue in queryList
        keystroke "a" using command down
        delay 0.05
        key code 51
        delay 0.1

        set queryChars to characters of queryValue
        repeat with c in queryChars
            keystroke c
            delay {key_delay}
        end repeat

        delay {query_delay}
    end repeat

    keystroke "a" using command down
    delay 0.05
    key code 51
end tell
"#,
        query_list = query_list,
        key_delay = millis_to_seconds(keystroke_delay_ms),
        query_delay = millis_to_seconds(query_delay_ms),
    );
    let output = Runner::new(reporter, "osascript")
        .arg("-")
        .stdin_bytes(script)
        .capture_stdout()
        .capture_stderr()
        .output_status()?;
    if !output.status.success() {
        return Err(anyhow!(
            "typing simulation failed with status {}",
            output.status
        ));
    }
    Ok(output.stderr)
}

fn is_clipkitty_running(reporter: &Reporter) -> Result<bool> {
    let output = Runner::new(reporter, "pgrep")
        .arg("-x")
        .arg(APP_NAME)
        .capture_stderr()
        .output_status()?;
    Ok(output.status.success())
}

fn millis_to_seconds(value_ms: u64) -> String {
    format!("{:.3}", value_ms as f64 / 1000.0)
}

fn locked_cargo() -> bool {
    env::var("LOCKED").is_ok_and(|value| value == "1")
}

fn remove_if_exists(path: &Utf8Path) -> Result<()> {
    if !path.as_std_path().exists() {
        return Ok(());
    }
    if path.as_std_path().is_dir() {
        fs::remove_dir_all(path.as_std_path()).with_context(|| format!("removing {path}"))?;
    } else {
        fs::remove_file(path.as_std_path()).with_context(|| format!("removing {path}"))?;
    }
    Ok(())
}

fn copy_dir_recursive(src: &Utf8Path, dst: &Utf8Path) -> Result<()> {
    if dst.as_std_path().exists() {
        fs::remove_dir_all(dst.as_std_path()).with_context(|| format!("removing {dst}"))?;
    }
    fs::create_dir_all(dst.as_std_path()).with_context(|| format!("creating {dst}"))?;
    for entry in fs::read_dir(src.as_std_path()).with_context(|| format!("reading {src}"))? {
        let entry = entry?;
        let child = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
        let dest = dst.join(child.file_name().unwrap());
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_recursive(&child, &dest)?;
        } else if file_type.is_file() {
            fs::copy(child.as_std_path(), dest.as_std_path())
                .with_context(|| format!("copying {child} to {dest}"))?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, PartialEq)]
struct HangEvent {
    duration_ms: f64,
    timestamp_ms: f64,
    function: String,
    backtrace: Option<String>,
    is_hang: bool,
}

#[derive(Debug, Clone, Serialize)]
struct AnalysisReport {
    trace_file: String,
    hang_threshold_ms: f64,
    stutter_threshold_ms: f64,
    total_samples: usize,
    hang_count: usize,
    stutter_count: usize,
    total_hang_duration_ms: f64,
    total_stutter_duration_ms: f64,
    max_duration_ms: f64,
    avg_duration_ms: f64,
    p95_duration_ms: f64,
    top_hangs: Vec<HangEvent>,
    top_stutters: Vec<HangEvent>,
    passed: bool,
}

fn analyze_trace(
    trace_path: &Utf8Path,
    hang_threshold_ms: f64,
    stutter_threshold_ms: f64,
    quiet: bool,
    ignore_first_ms: f64,
    reporter: &Reporter,
) -> Result<AnalysisReport> {
    let tempdir = TempDir::new().context("creating temporary directory for xctrace export")?;
    let xml_paths = export_trace_data(trace_path, tempdir.path(), quiet, reporter)?;

    if xml_paths.is_empty() {
        return Ok(AnalysisReport {
            trace_file: trace_path.to_string(),
            hang_threshold_ms,
            stutter_threshold_ms,
            total_samples: 0,
            hang_count: 0,
            stutter_count: 0,
            total_hang_duration_ms: 0.0,
            total_stutter_duration_ms: 0.0,
            max_duration_ms: 0.0,
            avg_duration_ms: 0.0,
            p95_duration_ms: 0.0,
            top_hangs: Vec::new(),
            top_stutters: Vec::new(),
            passed: true,
        });
    }

    let mut hangs = Vec::new();
    let mut stutters = Vec::new();
    let mut all_durations = Vec::new();
    let mut all_main_thread_gaps = Vec::new();
    for path in &xml_paths {
        let (file_hangs, file_stutters, file_durations, file_gaps) =
            parse_time_profile(path, hang_threshold_ms, stutter_threshold_ms)?;
        hangs.extend(file_hangs);
        stutters.extend(file_stutters);
        all_durations.extend(file_durations);
        all_main_thread_gaps.extend(file_gaps);
    }

    let all_timestamps = all_main_thread_gaps
        .iter()
        .map(|gap| gap.timestamp_ms)
        .filter(|ts| *ts > 0.0)
        .collect::<Vec<_>>();
    let trace_start_ms = all_timestamps.into_iter().reduce(f64::min).unwrap_or(0.0);
    if ignore_first_ms > 0.0 {
        let cutoff = trace_start_ms + ignore_first_ms;
        all_main_thread_gaps.retain(|gap| gap.timestamp_ms > cutoff);
    }

    let total_samples = all_durations.len();
    let total_hang_duration = hangs.iter().map(|hang| hang.duration_ms).sum::<f64>();
    let total_stutter_duration = stutters
        .iter()
        .map(|stutter| stutter.duration_ms)
        .sum::<f64>();

    let non_idle_gaps = all_main_thread_gaps
        .iter()
        .filter(|gap| !gap.is_idle)
        .cloned()
        .collect::<Vec<_>>();
    if !non_idle_gaps.is_empty() {
        for gap in &non_idle_gaps {
            let event = HangEvent {
                duration_ms: gap.duration_ms,
                timestamp_ms: gap.timestamp_ms,
                function: gap.function.clone(),
                backtrace: gap.backtrace.clone(),
                is_hang: gap.duration_ms >= hang_threshold_ms,
            };
            if event.is_hang {
                if !hangs.contains(&event) {
                    hangs.push(event);
                }
            } else if gap.duration_ms >= stutter_threshold_ms && !stutters.contains(&event) {
                stutters.push(event);
            }
        }
    }

    let max_duration = non_idle_gaps
        .iter()
        .map(|gap| gap.duration_ms)
        .reduce(f64::max)
        .or_else(|| {
            all_main_thread_gaps
                .iter()
                .map(|gap| gap.duration_ms)
                .reduce(f64::max)
        })
        .or_else(|| all_durations.iter().copied().reduce(f64::max))
        .unwrap_or(0.0);
    let avg_duration = if all_durations.is_empty() {
        0.0
    } else {
        all_durations.iter().sum::<f64>() / all_durations.len() as f64
    };
    let p95_duration = if all_main_thread_gaps.is_empty() {
        0.0
    } else {
        let mut sorted = all_main_thread_gaps
            .iter()
            .map(|gap| gap.duration_ms)
            .collect::<Vec<_>>();
        sorted.sort_by(f64::total_cmp);
        let index = ((sorted.len() as f64) * 0.95).floor() as usize;
        sorted[index.min(sorted.len() - 1)]
    };

    hangs.sort_by(|left, right| right.duration_ms.total_cmp(&left.duration_ms));
    stutters.sort_by(|left, right| right.duration_ms.total_cmp(&left.duration_ms));

    Ok(AnalysisReport {
        trace_file: trace_path.to_string(),
        hang_threshold_ms,
        stutter_threshold_ms,
        total_samples,
        hang_count: hangs.len(),
        stutter_count: stutters.len(),
        total_hang_duration_ms: round2(total_hang_duration),
        total_stutter_duration_ms: round2(total_stutter_duration),
        max_duration_ms: round2(max_duration),
        avg_duration_ms: round2(avg_duration),
        p95_duration_ms: round2(p95_duration),
        passed: hangs.is_empty(),
        top_hangs: hangs.into_iter().take(10).collect(),
        top_stutters: stutters.into_iter().take(10).collect(),
    })
}

fn export_trace_data(
    trace_path: &Utf8Path,
    output_dir: &Path,
    quiet: bool,
    reporter: &Reporter,
) -> Result<Vec<Utf8PathBuf>> {
    let mut exported = Vec::new();
    let hangs_path = Utf8PathBuf::from_path_buf(output_dir.join("potential_hangs.xml"))
        .map_err(|p| anyhow!("non-UTF-8 export path: {p:?}"))?;
    let time_profile_path = Utf8PathBuf::from_path_buf(output_dir.join("time_profile.xml"))
        .map_err(|p| anyhow!("non-UTF-8 export path: {p:?}"))?;

    for (path, xpath) in [
        (
            hangs_path,
            r#"/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]"#,
        ),
        (
            time_profile_path,
            r#"/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]"#,
        ),
    ] {
        let output = Runner::new(reporter, "xcrun")
            .args(["xctrace", "export", "--input"])
            .arg(trace_path.as_std_path())
            .arg("--xpath")
            .arg(xpath)
            .arg("--output")
            .arg(path.as_std_path())
            .capture_stderr()
            .output_status()?;
        if output.status.success() {
            let file_size = fs::metadata(path.as_std_path())
                .map(|meta| meta.len())
                .unwrap_or(0);
            if file_size > 100 {
                if !quiet {
                    reporter.info(&format!("  Exported {} ({} bytes)", path, file_size));
                }
                exported.push(path);
            }
        }
    }

    Ok(exported)
}

#[derive(Debug, Clone)]
struct MainThreadGap {
    duration_ms: f64,
    timestamp_ms: f64,
    function: String,
    backtrace: Option<String>,
    is_idle: bool,
}

fn parse_time_profile(
    xml_path: &Utf8Path,
    hang_threshold_ms: f64,
    stutter_threshold_ms: f64,
) -> Result<(Vec<HangEvent>, Vec<HangEvent>, Vec<f64>, Vec<MainThreadGap>)> {
    let xml = fs::read_to_string(xml_path.as_std_path())
        .with_context(|| format!("reading {xml_path}"))?;
    let doc = Document::parse(&xml).with_context(|| format!("parsing {xml_path}"))?;

    let mut value_lookup = BTreeMap::new();
    let mut thread_lookup = BTreeMap::new();
    let mut frame_lookup = BTreeMap::new();
    let mut backtrace_lookup: BTreeMap<String, Vec<(Option<String>, Option<String>)>> =
        BTreeMap::new();

    for node in doc.descendants().filter(|node| node.is_element()) {
        if let Some(id) = node.attribute("id") {
            if let Some(text) = node.text() {
                value_lookup.insert(id.to_string(), text.to_string());
            }
            if node.tag_name().name() == "thread" {
                if let Some(fmt) = node.attribute("fmt") {
                    thread_lookup.insert(id.to_string(), fmt.to_string());
                }
            }
            if node.tag_name().name() == "frame" {
                if let Some(name) = node.attribute("name") {
                    frame_lookup.insert(id.to_string(), name.to_string());
                }
            }
            if node.tag_name().name() == "backtrace" {
                let frames = node
                    .children()
                    .filter(|child| child.is_element() && child.tag_name().name() == "frame")
                    .map(|frame| {
                        (
                            frame.attribute("name").map(str::to_string),
                            frame.attribute("ref").map(str::to_string),
                        )
                    })
                    .collect::<Vec<_>>();
                backtrace_lookup.insert(id.to_string(), frames);
            }
        }
    }

    let mut hangs = Vec::new();
    let mut stutters = Vec::new();
    let mut all_durations = Vec::new();
    let mut main_thread_samples = Vec::new();

    for row in doc
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "row")
    {
        let is_main = row
            .descendants()
            .find(|node| node.is_element() && node.tag_name().name() == "thread")
            .is_some_and(|node| is_main_thread(node, &thread_lookup));

        let duration = find_numeric_value(row, "weight", &value_lookup)
            .or_else(|| find_numeric_value(row, "duration", &value_lookup))
            .map(|value| value / 1_000_000.0);
        let timestamp = find_numeric_value(row, "sample-time", &value_lookup)
            .or_else(|| find_numeric_value(row, "start-time", &value_lookup))
            .map(|value| value / 1_000_000.0);

        let (mut function, backtrace) = row
            .descendants()
            .find(|node| node.is_element() && node.tag_name().name() == "backtrace")
            .map(|node| resolve_backtrace(node, &backtrace_lookup, &frame_lookup))
            .unwrap_or_else(|| ("unknown".to_string(), None));

        if let Some(hang_type) = row
            .descendants()
            .find(|node| node.is_element() && node.tag_name().name() == "hang-type")
            .and_then(|node| {
                node_value(node, &value_lookup)
                    .or_else(|| node.attribute("fmt").map(str::to_string))
            })
        {
            function = format!("[{hang_type}] {function}");
        }

        if let Some(duration_ms) = duration.filter(|duration| *duration > 0.0) {
            all_durations.push(duration_ms);
            if is_main {
                if let Some(timestamp_ms) = timestamp {
                    main_thread_samples.push((timestamp_ms, function.clone(), backtrace.clone()));
                }
            }
            let event = HangEvent {
                duration_ms,
                timestamp_ms: timestamp.unwrap_or(0.0),
                function,
                backtrace,
                is_hang: duration_ms >= hang_threshold_ms,
            };
            if duration_ms >= hang_threshold_ms {
                hangs.push(event);
            } else if duration_ms >= stutter_threshold_ms {
                stutters.push(event);
            }
        }
    }

    main_thread_samples.sort_by(|left, right| left.0.total_cmp(&right.0));
    let mut gaps = Vec::new();
    for window in main_thread_samples.windows(2) {
        let (prev_ts, prev_func, prev_bt) = &window[0];
        let (curr_ts, curr_func, curr_bt) = &window[1];
        let gap = curr_ts - prev_ts;
        if gap > 0.0 {
            gaps.push(MainThreadGap {
                duration_ms: gap,
                timestamp_ms: *curr_ts,
                function: curr_func.clone(),
                backtrace: curr_bt.clone(),
                is_idle: is_gap_idle_period(
                    prev_func,
                    prev_bt.as_deref(),
                    curr_func,
                    curr_bt.as_deref(),
                ),
            });
        }
    }

    Ok((hangs, stutters, all_durations, gaps))
}

fn find_numeric_value(
    row: roxmltree::Node<'_, '_>,
    tag: &str,
    value_lookup: &BTreeMap<String, String>,
) -> Option<f64> {
    row.descendants()
        .find(|node| node.is_element() && node.tag_name().name() == tag)
        .and_then(|node| node_value(node, value_lookup))
        .and_then(|value| value.parse::<f64>().ok())
}

fn node_value(
    node: roxmltree::Node<'_, '_>,
    value_lookup: &BTreeMap<String, String>,
) -> Option<String> {
    node.text().map(str::to_string).or_else(|| {
        node.attribute("ref")
            .and_then(|reference| value_lookup.get(reference).cloned())
    })
}

fn is_main_thread(
    thread_node: roxmltree::Node<'_, '_>,
    thread_lookup: &BTreeMap<String, String>,
) -> bool {
    if let Some(fmt) = thread_node.attribute("fmt") {
        return fmt.contains("Main Thread");
    }
    thread_node
        .attribute("ref")
        .and_then(|reference| thread_lookup.get(reference))
        .is_some_and(|fmt| fmt.contains("Main Thread"))
}

fn resolve_backtrace(
    backtrace_node: roxmltree::Node<'_, '_>,
    backtrace_lookup: &BTreeMap<String, Vec<(Option<String>, Option<String>)>>,
    frame_lookup: &BTreeMap<String, String>,
) -> (String, Option<String>) {
    let frames = if let Some(reference) = backtrace_node.attribute("ref") {
        backtrace_lookup.get(reference).cloned().unwrap_or_default()
    } else {
        backtrace_node
            .children()
            .filter(|child| child.is_element() && child.tag_name().name() == "frame")
            .map(|frame| {
                (
                    frame.attribute("name").map(str::to_string),
                    frame.attribute("ref").map(str::to_string),
                )
            })
            .collect::<Vec<_>>()
    };

    let resolved = frames
        .into_iter()
        .map(|(name, reference)| {
            name.or_else(|| reference.and_then(|reference| frame_lookup.get(&reference).cloned()))
                .unwrap_or_else(|| "?".to_string())
        })
        .collect::<Vec<_>>();

    if resolved.is_empty() {
        ("unknown".to_string(), None)
    } else {
        (
            resolved[0].clone(),
            Some(resolved.into_iter().take(10).collect::<Vec<_>>().join("\n")),
        )
    }
}

fn is_idle_backtrace(function: &str, backtrace: Option<&str>) -> bool {
    let idle_patterns = [
        "mach_msg",
        "mach_msg2_trap",
        "__CFRunLoopRun",
        "__CFRunLoopServiceMachPort",
        "ReceiveNextEvent",
        "_BlockUntilNextEvent",
        "stepIdle",
    ];
    if idle_patterns
        .iter()
        .any(|pattern| function.contains(pattern))
    {
        return true;
    }
    if let Some(backtrace) = backtrace {
        for frame in backtrace.lines().take(3) {
            if idle_patterns.iter().any(|pattern| frame.contains(pattern)) {
                return true;
            }
        }
    }
    false
}

fn is_gap_idle_period(
    before_function: &str,
    before_backtrace: Option<&str>,
    after_function: &str,
    after_backtrace: Option<&str>,
) -> bool {
    let before_idle = is_idle_backtrace(before_function, before_backtrace);
    let after_idle = is_idle_backtrace(after_function, after_backtrace);
    if before_idle && after_idle {
        return true;
    }
    if before_idle && !after_idle {
        let housekeeping = [
            "stepTransactionFlush",
            "objc_autoreleasePoolPop",
            "__CFRunLoopDoObservers",
            "__CFRunLoopDoBlocks",
        ];
        if housekeeping
            .iter()
            .any(|pattern| after_function.contains(pattern))
        {
            return true;
        }
        if let Some(backtrace) = after_backtrace {
            if housekeeping
                .iter()
                .any(|pattern| backtrace.contains(pattern))
            {
                return true;
            }
        }
    }
    false
}

fn print_report(report: &AnalysisReport, reporter: &Reporter) {
    reporter.info("");
    reporter.info("============================================================");
    reporter.info("PERFORMANCE TRACE ANALYSIS");
    reporter.info("============================================================");
    reporter.info(&format!("Trace file: {}", report.trace_file));
    reporter.info(&format!("Hang threshold: {}ms", report.hang_threshold_ms));
    reporter.info(&format!(
        "Stutter threshold: {}ms",
        report.stutter_threshold_ms
    ));
    reporter.info("");
    reporter.info("--- Summary ---");
    reporter.info(&format!("Total samples analyzed: {}", report.total_samples));
    reporter.info(&format!("Average duration: {}ms", report.avg_duration_ms));
    reporter.info(&format!("Max duration: {}ms", report.max_duration_ms));
    reporter.info(&format!("P95 duration: {}ms", report.p95_duration_ms));
    reporter.info("");
    reporter.info(&format!(
        "--- Hangs (>= {}ms) ---",
        report.hang_threshold_ms
    ));
    reporter.info(&format!("Count: {}", report.hang_count));
    reporter.info(&format!(
        "Total duration: {}ms",
        report.total_hang_duration_ms
    ));
    if !report.top_hangs.is_empty() {
        reporter.info("");
        reporter.info("Top hangs:");
        for (index, hang) in report.top_hangs.iter().take(5).enumerate() {
            reporter.info(&format!(
                "  {}. {:.1}ms - {}",
                index + 1,
                hang.duration_ms,
                hang.function
            ));
        }
    }
    reporter.info("");
    reporter.info(&format!(
        "--- Stutters ({}-{}ms) ---",
        report.stutter_threshold_ms, report.hang_threshold_ms
    ));
    reporter.info(&format!("Count: {}", report.stutter_count));
    reporter.info(&format!(
        "Total duration: {}ms",
        report.total_stutter_duration_ms
    ));
    reporter.info("");
    reporter.info("============================================================");
    if report.passed {
        reporter.info("PASS: No main thread hangs detected");
    } else {
        reporter.info(&format!(
            "FAIL: Detected {} main thread hang(s)",
            report.hang_count
        ));
    }
    reporter.info("============================================================");
}

fn round2(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

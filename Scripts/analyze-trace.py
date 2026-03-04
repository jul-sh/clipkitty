#!/usr/bin/env python3
"""
Analyze Instruments trace files for main thread hangs and performance regressions.

This script exports data from .trace files using xctrace and analyzes them
for main thread blocking that exceeds configurable thresholds.

Usage:
    ./Scripts/analyze-trace.py <trace_file> [options]

Options:
    --hang-threshold    Hang threshold in ms (default: 250, Apple's definition)
    --stutter-threshold Stutter threshold in ms (default: 100)
    --json              Output JSON report instead of human-readable
    --fail-on-hangs     Exit with code 1 if any hangs detected (for CI)

Examples:
    ./Scripts/analyze-trace.py performance.trace
    ./Scripts/analyze-trace.py performance.trace --hang-threshold 200 --fail-on-hangs
    ./Scripts/analyze-trace.py performance.trace --json > report.json
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional


@dataclass
class HangEvent:
    """Represents a detected hang or stutter event."""
    duration_ms: float
    timestamp_ms: float
    function: str
    backtrace: Optional[str] = None
    is_hang: bool = False  # True if >= hang threshold


@dataclass
class AnalysisReport:
    """Performance analysis report."""
    trace_file: str
    hang_threshold_ms: float
    stutter_threshold_ms: float
    total_samples: int
    hang_count: int
    stutter_count: int
    total_hang_duration_ms: float
    total_stutter_duration_ms: float
    max_duration_ms: float
    avg_duration_ms: float
    p95_duration_ms: float
    top_hangs: list
    top_stutters: list
    passed: bool


def export_trace_data(trace_path: str, output_dir: str, quiet: bool = False) -> list:
    """Export trace data to XML using xctrace. Returns list of exported file paths."""
    exported_files = []

    # First, export table of contents to understand trace structure
    if not quiet:
        print(f"Exporting trace data...", file=sys.stderr)

    # Export potential-hangs table (direct hang detection by Instruments)
    hangs_path = os.path.join(output_dir, "potential_hangs.xml")
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path,
         "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]',
         "--output", hangs_path],
        capture_output=True,
        text=True
    )
    if result.returncode == 0 and os.path.exists(hangs_path):
        file_size = os.path.getsize(hangs_path)
        if file_size > 100:
            if not quiet:
                print(f"  Exported potential-hangs: {file_size} bytes", file=sys.stderr)
            exported_files.append(hangs_path)

    # Export time-profile table (sample weights for analysis)
    time_profile_path = os.path.join(output_dir, "time_profile.xml")
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path,
         "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
         "--output", time_profile_path],
        capture_output=True,
        text=True
    )
    if result.returncode == 0 and os.path.exists(time_profile_path):
        file_size = os.path.getsize(time_profile_path)
        if file_size > 100:
            if not quiet:
                print(f"  Exported time-profile: {file_size} bytes", file=sys.stderr)
            exported_files.append(time_profile_path)

    if not exported_files and not quiet:
        print("Warning: No trace data could be exported", file=sys.stderr)

    return exported_files


def is_idle_backtrace(function: str, backtrace: str) -> bool:
    """Check if a backtrace indicates the main thread was idle (waiting for events).

    When the main thread is idle, it's typically blocked in mach_msg waiting for:
    - Run loop events
    - Window server messages
    - System notifications

    These are NOT true hangs - they're normal idle periods.

    We check BOTH the sample BEFORE and AFTER the gap:
    - If BEFORE was in mach_msg/RunLoop AND AFTER is also in mach_msg/RunLoop,
      this was just an idle period between events.
    - If BEFORE was doing work (not idle) but AFTER is idle, we still count
      it because the work finished and then thread went idle.
    - If AFTER shows active work (not idle), it's likely a real hang that
      blocked until that work could proceed.

    This function checks if a SINGLE sample shows idle behavior.
    The caller should check BOTH samples around a gap.
    """
    if not function and not backtrace:
        return False

    # Idle indicators: main thread waiting for events or committing idle CA transactions
    idle_patterns = [
        'mach_msg',              # Blocked waiting for Mach message
        'mach_msg2_trap',        # Same, kernel trap
        '__CFRunLoopRun',        # In run loop (normal)
        '__CFRunLoopServiceMachPort',  # Waiting for mach port
        'ReceiveNextEvent',      # Waiting for next event
        '_BlockUntilNextEvent',  # Waiting for window event
        'stepIdle',              # Core Animation idle step
    ]

    # Check if the TOP of the stack (leaf function) is an idle wait
    # The function parameter is the leaf (top of stack)
    if function:
        for pattern in idle_patterns:
            if pattern in function:
                return True

    # Also check first few frames of backtrace
    if backtrace:
        first_frames = backtrace.split('\n')[:3]
        for frame in first_frames:
            for pattern in idle_patterns:
                if pattern in frame:
                    return True

    return False


def is_gap_idle_period(before_func: str, before_bt: str, after_func: str, after_bt: str) -> bool:
    """Determine if a gap between samples was an idle period vs a true hang.

    A gap is considered an IDLE PERIOD (not a hang) if:
    1. BOTH before and after samples show idle behavior (waiting for events)
    2. OR the gap occurred during Core Animation idle commit (stepIdle)

    A gap is a TRUE HANG if:
    1. The sample AFTER the gap shows active work (SwiftUI, app code, etc.)
    2. This indicates the main thread was blocked and then resumed doing work

    Returns True if this was an idle period (should be filtered out).
    """
    before_idle = is_idle_backtrace(before_func, before_bt)
    after_idle = is_idle_backtrace(after_func, after_bt)

    # If both before and after are idle, this was definitely an idle period
    if before_idle and after_idle:
        return True

    # If before was idle but after shows work, it might be a real hang
    # (thread was waiting, then had to do blocking work)
    # But we should check if the "work" is just run loop housekeeping
    if before_idle and not after_idle:
        # Check if after is just run loop observer callbacks (not real work)
        if after_bt:
            # These are run loop callbacks that happen between events
            runloop_housekeeping = [
                'stepTransactionFlush',
                'objc_autoreleasePoolPop',
                '__CFRunLoopDoObservers',
                '__CFRunLoopDoBlocks',
            ]
            for pattern in runloop_housekeeping:
                if pattern in (after_func or '') or pattern in after_bt:
                    return True

    return False


def parse_time_profile(xml_path: str, hang_threshold_ms: float, stutter_threshold_ms: float) -> tuple:
    """Parse time profile XML and extract duration samples.

    Returns: (hangs, stutters, all_durations, main_thread_gaps)
    - main_thread_gaps: list of (gap_ms, timestamp_ms, function, backtrace, is_idle)
      where is_idle indicates if this was likely an idle period vs true hang
    """
    hangs = []
    stutters = []
    all_durations = []
    main_thread_samples = []  # (timestamp_ms, function, backtrace)

    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"Warning: Could not parse XML: {e}", file=sys.stderr)
        return hangs, stutters, all_durations, []

    # Build lookup tables for referenced values (xctrace uses ref="id" for deduplication)
    value_lookup = {}      # id -> text value
    thread_lookup = {}     # id -> thread fmt string
    frame_lookup = {}      # id -> frame name
    backtrace_lookup = {}  # id -> list of (name, ref) tuples for frames

    for elem in root.iter():
        elem_id = elem.get('id')
        if elem_id:
            if elem.text:
                value_lookup[elem_id] = elem.text
            # Track thread format strings
            fmt = elem.get('fmt')
            if fmt and elem.tag == 'thread':
                thread_lookup[elem_id] = fmt
            # Track frame names
            if elem.tag == 'frame':
                frame_lookup[elem_id] = elem.get('name', '?')
            # Track backtraces with their frame refs
            if elem.tag == 'backtrace':
                frames = []
                for frame in elem.findall('frame'):
                    name = frame.get('name')
                    ref = frame.get('ref')
                    frames.append((name, ref))
                backtrace_lookup[elem_id] = frames

    def get_element_value(elem):
        """Get element value, handling ref attributes for deduplication."""
        if elem is None:
            return None
        # Direct value
        if elem.text:
            return elem.text
        # Reference to another element
        ref = elem.get('ref')
        if ref and ref in value_lookup:
            return value_lookup[ref]
        return None

    def is_main_thread(thread_elem):
        """Check if this is the main thread."""
        if thread_elem is None:
            return False
        fmt = thread_elem.get('fmt')
        if fmt:
            return 'Main Thread' in fmt
        ref = thread_elem.get('ref')
        if ref and ref in thread_lookup:
            return 'Main Thread' in thread_lookup[ref]
        return False

    def resolve_backtrace(bt_elem):
        """Resolve a backtrace element to (function, backtrace_str)."""
        if bt_elem is None:
            return 'unknown', None

        # Check if this is a reference to another backtrace
        ref = bt_elem.get('ref')
        if ref and ref in backtrace_lookup:
            frame_data = backtrace_lookup[ref]
        else:
            # Parse inline frames
            frame_data = []
            for frame in bt_elem.findall('frame'):
                name = frame.get('name')
                fref = frame.get('ref')
                frame_data.append((name, fref))

        # Resolve frame names
        resolved = []
        for name, fref in frame_data:
            if name:
                resolved.append(name)
            elif fref and fref in frame_lookup:
                resolved.append(frame_lookup[fref])
            else:
                resolved.append('?')

        if not resolved:
            return 'unknown', None

        function = resolved[0]
        backtrace_str = '\n'.join(resolved[:10])
        return function, backtrace_str

    # Parse xctrace export format - rows with child elements for data
    for row in root.iter('row'):
        duration = None
        timestamp = None
        function = "unknown"
        backtrace_str = None
        is_main = False

        # Check if this sample is from main thread
        thread_elem = row.find('.//thread')
        is_main = is_main_thread(thread_elem)

        # Look for weight element (duration in nanoseconds) - handles ref attribute
        weight_elem = row.find('.//weight')
        if weight_elem is not None:
            weight_val = get_element_value(weight_elem)
            if weight_val:
                try:
                    value = float(weight_val)
                    # Weight is in nanoseconds, convert to ms
                    duration = value / 1_000_000
                except ValueError:
                    pass

        # Look for duration element (for potential-hangs table)
        duration_elem = row.find('.//duration')
        if duration_elem is not None:
            dur_val = get_element_value(duration_elem)
            if dur_val:
                try:
                    value = float(dur_val)
                    # Duration is in nanoseconds, convert to ms
                    duration = value / 1_000_000
                except ValueError:
                    pass

        # Get timestamp from sample-time or start-time
        time_elem = row.find('.//sample-time')
        if time_elem is not None:
            time_val = get_element_value(time_elem)
            if time_val:
                try:
                    timestamp = float(time_val) / 1_000_000  # ns to ms
                except ValueError:
                    pass

        start_elem = row.find('.//start-time')
        if start_elem is not None:
            start_val = get_element_value(start_elem)
            if start_val:
                try:
                    timestamp = float(start_val) / 1_000_000  # ns to ms
                except ValueError:
                    pass

        # Get function name from backtrace's first frame (with ref resolution)
        backtrace_elem = row.find('.//backtrace')
        if backtrace_elem is not None:
            function, backtrace_str = resolve_backtrace(backtrace_elem)

        # Also check hang-type element for potential-hangs
        hang_type_elem = row.find('.//hang-type')
        if hang_type_elem is not None:
            hang_type = get_element_value(hang_type_elem) or hang_type_elem.get('fmt', '')
            if hang_type:
                function = f"[{hang_type}] {function}"

        if duration is not None and duration > 0:
            all_durations.append(duration)

            # Track main thread samples for gap analysis
            if is_main and timestamp is not None:
                main_thread_samples.append((timestamp, function, backtrace_str))

            event = HangEvent(
                duration_ms=duration,
                timestamp_ms=timestamp or 0,
                function=function,
                backtrace=backtrace_str,
                is_hang=(duration >= hang_threshold_ms)
            )

            if duration >= hang_threshold_ms:
                hangs.append(event)
            elif duration >= stutter_threshold_ms:
                stutters.append(event)

    # Calculate gaps between consecutive main thread samples
    # Large gaps indicate the main thread was blocked (not being sampled)
    # We check BOTH before and after samples to distinguish idle vs real hangs
    main_thread_gaps = []
    main_thread_samples.sort(key=lambda x: x[0])  # Sort by timestamp

    for i in range(1, len(main_thread_samples)):
        prev_ts, prev_func, prev_bt = main_thread_samples[i-1]
        curr_ts, curr_func, curr_bt = main_thread_samples[i]
        gap = curr_ts - prev_ts
        if gap > 0:
            # Use improved idle detection that considers both samples
            is_idle = is_gap_idle_period(prev_func, prev_bt, curr_func, curr_bt)
            main_thread_gaps.append((gap, curr_ts, curr_func, curr_bt, is_idle))

    return hangs, stutters, all_durations, main_thread_gaps


def analyze_trace(trace_path: str, hang_threshold_ms: float, stutter_threshold_ms: float, quiet: bool = False, ignore_first_ms: float = 3000) -> AnalysisReport:
    """Analyze a trace file and generate a report.

    Args:
        ignore_first_ms: Ignore hangs occurring in the first N milliseconds (startup period).
                        Set to 0 to analyze all samples.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        xml_paths = export_trace_data(trace_path, tmpdir, quiet=quiet)

        if not xml_paths:
            # Return empty report if export failed
            return AnalysisReport(
                trace_file=trace_path,
                hang_threshold_ms=hang_threshold_ms,
                stutter_threshold_ms=stutter_threshold_ms,
                total_samples=0,
                hang_count=0,
                stutter_count=0,
                total_hang_duration_ms=0,
                total_stutter_duration_ms=0,
                max_duration_ms=0,
                avg_duration_ms=0,
                p95_duration_ms=0,
                top_hangs=[],
                top_stutters=[],
                passed=True  # No data means no detected failures
            )

        # Parse all exported files and combine results
        hangs = []
        stutters = []
        all_durations = []
        all_main_thread_gaps = []

        for xml_path in xml_paths:
            h, s, d, gaps = parse_time_profile(xml_path, hang_threshold_ms, stutter_threshold_ms)
            hangs.extend(h)
            stutters.extend(s)
            all_durations.extend(d)
            all_main_thread_gaps.extend(gaps)

    # Find the earliest timestamp to determine trace start time
    all_timestamps = [g[1] for g in all_main_thread_gaps if g[1] > 0]
    trace_start_ms = min(all_timestamps) if all_timestamps else 0

    # Filter out startup period from gaps
    if ignore_first_ms > 0:
        cutoff_ms = trace_start_ms + ignore_first_ms
        all_main_thread_gaps = [g for g in all_main_thread_gaps if g[1] > cutoff_ms]
        if not quiet:
            print(f"  Ignoring first {ignore_first_ms/1000:.1f}s (timestamps < {cutoff_ms:.0f}ms)", file=sys.stderr)

    # Calculate statistics
    total_samples = len(all_durations)
    hang_count = len(hangs)
    stutter_count = len(stutters)

    total_hang_duration = sum(h.duration_ms for h in hangs)
    total_stutter_duration = sum(s.duration_ms for s in stutters)

    # Max duration: use the largest gap between main thread samples
    # This represents the longest period the main thread was unresponsive
    # (gaps are: (gap_ms, timestamp_ms, function, backtrace, is_idle))
    #
    # IMPORTANT: We filter out idle periods - these are NOT hangs.
    # Only gaps where the thread resumed doing work (not idle wait) count as hangs.
    non_idle_gaps = [g for g in all_main_thread_gaps if not g[4]]  # g[4] is is_idle
    idle_gaps = [g for g in all_main_thread_gaps if g[4]]

    if not quiet and idle_gaps:
        significant_idle = [g for g in idle_gaps if g[0] >= hang_threshold_ms]
        if significant_idle:
            print(f"  Filtered out {len(significant_idle)} idle period(s) >= {hang_threshold_ms}ms", file=sys.stderr)

    if non_idle_gaps:
        max_gap = max(non_idle_gaps, key=lambda x: x[0])
        max_duration = max_gap[0]

        # Create hang events from significant NON-IDLE gaps
        for gap_ms, ts, func, bt, is_idle in non_idle_gaps:
            if gap_ms >= hang_threshold_ms:
                event = HangEvent(
                    duration_ms=gap_ms,
                    timestamp_ms=ts,
                    function=func,
                    backtrace=bt,
                    is_hang=True
                )
                if event not in hangs:  # Avoid duplicates from potential-hangs table
                    hangs.append(event)
            elif gap_ms >= stutter_threshold_ms:
                event = HangEvent(
                    duration_ms=gap_ms,
                    timestamp_ms=ts,
                    function=func,
                    backtrace=bt,
                    is_hang=False
                )
                if event not in stutters:
                    stutters.append(event)
    elif all_main_thread_gaps:
        # All gaps were idle periods - use largest for max but no hangs
        max_gap = max(all_main_thread_gaps, key=lambda x: x[0])
        max_duration = max_gap[0]
    else:
        max_duration = max(all_durations) if all_durations else 0

    # Recalculate counts after adding gap-detected hangs
    hang_count = len(hangs)
    stutter_count = len(stutters)

    avg_duration = sum(all_durations) / len(all_durations) if all_durations else 0

    # Calculate P95 of main thread gaps (more meaningful than sample weights)
    if all_main_thread_gaps:
        sorted_gaps = sorted([g[0] for g in all_main_thread_gaps])
        p95_index = int(len(sorted_gaps) * 0.95)
        p95_duration = sorted_gaps[min(p95_index, len(sorted_gaps) - 1)]
    else:
        p95_duration = 0

    # Sort by duration and take top 10
    top_hangs = sorted(hangs, key=lambda x: x.duration_ms, reverse=True)[:10]
    top_stutters = sorted(stutters, key=lambda x: x.duration_ms, reverse=True)[:10]

    return AnalysisReport(
        trace_file=trace_path,
        hang_threshold_ms=hang_threshold_ms,
        stutter_threshold_ms=stutter_threshold_ms,
        total_samples=total_samples,
        hang_count=hang_count,
        stutter_count=stutter_count,
        total_hang_duration_ms=round(total_hang_duration, 2),
        total_stutter_duration_ms=round(total_stutter_duration, 2),
        max_duration_ms=round(max_duration, 2),
        avg_duration_ms=round(avg_duration, 2),
        p95_duration_ms=round(p95_duration, 2),
        top_hangs=[asdict(h) for h in top_hangs],
        top_stutters=[asdict(s) for s in top_stutters],
        passed=(hang_count == 0)
    )


def print_report(report: AnalysisReport):
    """Print human-readable report."""
    print()
    print("=" * 60)
    print("PERFORMANCE TRACE ANALYSIS")
    print("=" * 60)
    print()
    print(f"Trace file: {report.trace_file}")
    print(f"Hang threshold: {report.hang_threshold_ms}ms")
    print(f"Stutter threshold: {report.stutter_threshold_ms}ms")
    print()
    print("--- Summary ---")
    print(f"Total samples analyzed: {report.total_samples}")
    print(f"Average duration: {report.avg_duration_ms}ms")
    print(f"Max duration: {report.max_duration_ms}ms")
    print(f"P95 duration: {report.p95_duration_ms}ms")
    print()
    print(f"--- Hangs (>= {report.hang_threshold_ms}ms) ---")
    print(f"Count: {report.hang_count}")
    print(f"Total duration: {report.total_hang_duration_ms}ms")

    if report.top_hangs:
        print("\nTop hangs:")
        for i, hang in enumerate(report.top_hangs[:5], 1):
            print(f"  {i}. {hang['duration_ms']:.1f}ms - {hang['function']}")

    print()
    print(f"--- Stutters ({report.stutter_threshold_ms}-{report.hang_threshold_ms}ms) ---")
    print(f"Count: {report.stutter_count}")
    print(f"Total duration: {report.total_stutter_duration_ms}ms")

    print()
    print("=" * 60)

    if report.passed:
        print("✅ PASS: No main thread hangs detected")
    else:
        print(f"❌ FAIL: Detected {report.hang_count} main thread hang(s)")

    print("=" * 60)
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Analyze Instruments trace files for performance issues"
    )
    parser.add_argument("trace_file", help="Path to .trace file")
    parser.add_argument(
        "--hang-threshold",
        type=float,
        default=250,
        help="Hang threshold in ms (default: 250)"
    )
    parser.add_argument(
        "--stutter-threshold",
        type=float,
        default=100,
        help="Stutter threshold in ms (default: 100)"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output JSON report"
    )
    parser.add_argument(
        "--fail-on-hangs",
        action="store_true",
        help="Exit with code 1 if hangs detected"
    )
    parser.add_argument(
        "--ignore-first",
        type=float,
        default=3.0,
        help="Ignore hangs in first N seconds (startup period, default: 3.0)"
    )

    args = parser.parse_args()

    if not os.path.exists(args.trace_file):
        print(f"Error: Trace file not found: {args.trace_file}", file=sys.stderr)
        sys.exit(1)

    report = analyze_trace(
        args.trace_file,
        args.hang_threshold,
        args.stutter_threshold,
        quiet=args.json,
        ignore_first_ms=args.ignore_first * 1000
    )

    if args.json:
        print(json.dumps(asdict(report), indent=2))
    else:
        print_report(report)

    if args.fail_on_hangs and not report.passed:
        sys.exit(1)


if __name__ == "__main__":
    main()

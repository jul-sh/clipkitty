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


def export_trace_data(trace_path: str, output_dir: str) -> Optional[str]:
    """Export trace data to XML using xctrace."""
    toc_path = os.path.join(output_dir, "toc.xml")
    time_profile_path = os.path.join(output_dir, "time_profile.xml")

    # First, export table of contents to understand trace structure
    print(f"Exporting trace table of contents...")
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path, "--toc", "--output", toc_path],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        print(f"Warning: Failed to export TOC: {result.stderr}", file=sys.stderr)

    # Try to export time profile data
    print(f"Exporting time profile data...")

    # Try different XPath expressions for different Instruments templates
    xpaths = [
        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
        '/trace-toc/run[@number="1"]/tracks/track/table[@schema="time-profile"]',
        '/trace-toc/run/data/table',
    ]

    for xpath in xpaths:
        result = subprocess.run(
            ["xcrun", "xctrace", "export", "--input", trace_path, "--xpath", xpath, "--output", time_profile_path],
            capture_output=True,
            text=True
        )

        if result.returncode == 0 and os.path.exists(time_profile_path):
            file_size = os.path.getsize(time_profile_path)
            if file_size > 100:  # Non-empty file
                print(f"  Exported {file_size} bytes using xpath: {xpath}")
                return time_profile_path

    # If time profile export failed, try exporting all data
    print("Time profile export failed, trying generic export...")
    all_data_path = os.path.join(output_dir, "all_data.xml")
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path, "--output", all_data_path],
        capture_output=True,
        text=True
    )

    if result.returncode == 0 and os.path.exists(all_data_path):
        return all_data_path

    print(f"Error: Could not export trace data: {result.stderr}", file=sys.stderr)
    return None


def parse_time_profile(xml_path: str, hang_threshold_ms: float, stutter_threshold_ms: float) -> tuple:
    """Parse time profile XML and extract duration samples."""
    hangs = []
    stutters = []
    all_durations = []

    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"Warning: Could not parse XML: {e}", file=sys.stderr)
        return hangs, stutters, all_durations

    # Look for duration information in various XML structures
    # The exact structure depends on Instruments template and version

    # Try finding rows with duration/weight attributes
    for row in root.iter():
        # Check various attribute names that might contain duration info
        duration = None
        for attr in ['duration', 'weight', 'self-weight', 'total-weight', 'sample-count']:
            if attr in row.attrib:
                try:
                    # Duration might be in nanoseconds, microseconds, or milliseconds
                    value = float(row.attrib[attr])

                    # Heuristic: if value > 1000000, assume nanoseconds
                    # if value > 1000, assume microseconds
                    if value > 1_000_000_000:
                        duration = value / 1_000_000  # ns to ms
                    elif value > 1_000_000:
                        duration = value / 1_000  # us to ms
                    else:
                        duration = value  # assume ms

                    break
                except ValueError:
                    continue

        if duration is not None and duration > 0:
            all_durations.append(duration)

            # Get function/symbol name
            function = row.attrib.get('symbol', row.attrib.get('name', row.tag))

            # Get timestamp if available
            timestamp = float(row.attrib.get('start', row.attrib.get('time', 0)))

            # Get backtrace if available
            backtrace = None
            bt_elem = row.find('.//backtrace')
            if bt_elem is not None and bt_elem.text:
                backtrace = bt_elem.text

            event = HangEvent(
                duration_ms=duration,
                timestamp_ms=timestamp,
                function=function,
                backtrace=backtrace,
                is_hang=(duration >= hang_threshold_ms)
            )

            if duration >= hang_threshold_ms:
                hangs.append(event)
            elif duration >= stutter_threshold_ms:
                stutters.append(event)

    return hangs, stutters, all_durations


def analyze_trace(trace_path: str, hang_threshold_ms: float, stutter_threshold_ms: float) -> AnalysisReport:
    """Analyze a trace file and generate a report."""
    with tempfile.TemporaryDirectory() as tmpdir:
        xml_path = export_trace_data(trace_path, tmpdir)

        if xml_path is None:
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

        hangs, stutters, all_durations = parse_time_profile(xml_path, hang_threshold_ms, stutter_threshold_ms)

    # Calculate statistics
    total_samples = len(all_durations)
    hang_count = len(hangs)
    stutter_count = len(stutters)

    total_hang_duration = sum(h.duration_ms for h in hangs)
    total_stutter_duration = sum(s.duration_ms for s in stutters)

    max_duration = max(all_durations) if all_durations else 0
    avg_duration = sum(all_durations) / len(all_durations) if all_durations else 0

    # Calculate P95
    if all_durations:
        sorted_durations = sorted(all_durations)
        p95_index = int(len(sorted_durations) * 0.95)
        p95_duration = sorted_durations[min(p95_index, len(sorted_durations) - 1)]
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

    args = parser.parse_args()

    if not os.path.exists(args.trace_file):
        print(f"Error: Trace file not found: {args.trace_file}", file=sys.stderr)
        sys.exit(1)

    report = analyze_trace(args.trace_file, args.hang_threshold, args.stutter_threshold)

    if args.json:
        print(json.dumps(asdict(report), indent=2))
    else:
        print_report(report)

    if args.fail_on_hangs and not report.passed:
        sys.exit(1)


if __name__ == "__main__":
    main()

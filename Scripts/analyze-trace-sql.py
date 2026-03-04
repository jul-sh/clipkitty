#!/usr/bin/env python3
"""
Analyze Instruments trace files using SQLite for queryable analysis.

This script exports xctrace data and loads it into an SQLite database,
enabling SQL queries for more consistent and flexible analysis.

Usage:
    ./Scripts/analyze-trace-sql.py <trace_file> [options]
    ./Scripts/analyze-trace-sql.py <trace_file> --interactive  # Open SQL shell

Options:
    --hang-threshold    Hang threshold in ms (default: 250)
    --stutter-threshold Stutter threshold in ms (default: 100)
    --json              Output JSON report
    --interactive       Open interactive SQL shell
    --db-only           Only create the database, don't analyze
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional, List, Tuple


def export_trace_to_xml(trace_path: str, output_dir: str) -> str:
    """Export time-profile table from trace to XML."""
    xml_path = os.path.join(output_dir, "time_profile.xml")
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path,
         "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
         "--output", xml_path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"xctrace export failed: {result.stderr}", file=sys.stderr)
        return None
    return xml_path


def create_database(db_path: str) -> sqlite3.Connection:
    """Create SQLite database with schema for trace analysis."""
    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS samples (
            id INTEGER PRIMARY KEY,
            timestamp_ns INTEGER,
            timestamp_ms REAL,
            thread_name TEXT,
            thread_id TEXT,
            process_name TEXT,
            is_main_thread BOOLEAN,
            weight_ns INTEGER,
            weight_ms REAL,
            function TEXT,
            backtrace TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS main_thread_gaps (
            id INTEGER PRIMARY KEY,
            gap_ms REAL,
            timestamp_ms REAL,
            before_function TEXT,
            after_function TEXT,
            before_backtrace TEXT,
            after_backtrace TEXT,
            is_idle BOOLEAN
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_samples_thread ON samples(is_main_thread)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples(timestamp_ms)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_gaps_duration ON main_thread_gaps(gap_ms)")
    return conn


def is_idle_backtrace(function: str, backtrace: str) -> bool:
    """Check if backtrace indicates idle main thread."""
    idle_patterns = [
        'mach_msg', 'mach_msg2_trap', '__CFRunLoopRun',
        '__CFRunLoopServiceMachPort', 'ReceiveNextEvent',
        '_BlockUntilNextEvent', 'stepIdle',
    ]

    if function:
        for pattern in idle_patterns:
            if pattern in function:
                return True

    if backtrace:
        first_frames = backtrace.split('\n')[:3]
        for frame in first_frames:
            for pattern in idle_patterns:
                if pattern in frame:
                    return True
    return False


def parse_xml_to_db(xml_path: str, conn: sqlite3.Connection) -> int:
    """Parse xctrace XML and load into SQLite database."""
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"XML parse error: {e}", file=sys.stderr)
        return 0

    # Build lookup tables for refs
    value_lookup = {}
    thread_lookup = {}
    frame_lookup = {}
    backtrace_lookup = {}

    for elem in root.iter():
        elem_id = elem.get('id')
        if elem_id:
            if elem.text:
                value_lookup[elem_id] = elem.text
            fmt = elem.get('fmt')
            if fmt and elem.tag == 'thread':
                thread_lookup[elem_id] = fmt
            if elem.tag == 'frame':
                frame_lookup[elem_id] = elem.get('name', '?')
            if elem.tag == 'backtrace':
                frames = [(f.get('name'), f.get('ref')) for f in elem.findall('frame')]
                backtrace_lookup[elem_id] = frames

    def get_value(elem):
        if elem is None:
            return None
        ref = elem.get('ref')
        if ref and ref in value_lookup:
            return value_lookup[ref]
        if elem.text:
            return elem.text
        fmt = elem.get('fmt')
        return fmt

    def is_main_thread(thread_elem):
        if thread_elem is None:
            return False
        fmt = thread_elem.get('fmt', '')
        ref = thread_elem.get('ref')
        if 'Main Thread' in fmt:
            return True
        if ref and ref in thread_lookup:
            return 'Main Thread' in thread_lookup[ref]
        return False

    def resolve_backtrace(bt_elem):
        if bt_elem is None:
            return 'unknown', None
        ref = bt_elem.get('ref')
        if ref and ref in backtrace_lookup:
            frame_data = backtrace_lookup[ref]
        else:
            frame_data = [(f.get('name'), f.get('ref')) for f in bt_elem.findall('frame')]

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
        return resolved[0], '\n'.join(resolved[:15])

    # Parse rows
    samples = []
    for row in root.iter('row'):
        timestamp_ns = None
        thread_name = None
        thread_id = None
        process_name = None
        is_main = False
        weight_ns = 1000000  # Default 1ms

        # Parse sample-time
        time_elem = row.find('.//sample-time')
        if time_elem is not None:
            try:
                timestamp_ns = int(time_elem.text or time_elem.get('fmt', '0').replace(':', '').replace('.', ''))
            except ValueError:
                # Try parsing formatted time like "00:01.016.226"
                fmt = time_elem.get('fmt', '')
                match = re.match(r'(\d+):(\d+)\.(\d+)\.(\d+)', fmt)
                if match:
                    mins, secs, ms, us = map(int, match.groups())
                    timestamp_ns = ((mins * 60 + secs) * 1000 + ms) * 1000000 + us * 1000
                elif time_elem.text:
                    try:
                        timestamp_ns = int(time_elem.text)
                    except ValueError:
                        continue

        # Parse thread
        thread_elem = row.find('.//thread')
        if thread_elem is not None:
            thread_name = thread_elem.get('fmt', '')
            tid_elem = thread_elem.find('tid')
            if tid_elem is not None:
                thread_id = tid_elem.get('fmt', tid_elem.text)
            is_main = is_main_thread(thread_elem)

        # Parse process
        process_elem = row.find('.//process')
        if process_elem is not None:
            process_name = process_elem.get('fmt', '')

        # Parse weight
        weight_elem = row.find('.//weight')
        if weight_elem is not None:
            try:
                weight_ns = int(weight_elem.text or 1000000)
            except ValueError:
                weight_ns = 1000000

        # Parse backtrace
        backtrace_elem = row.find('.//backtrace')
        function, backtrace = resolve_backtrace(backtrace_elem)

        if timestamp_ns is not None:
            samples.append((
                timestamp_ns,
                timestamp_ns / 1000000.0,  # timestamp_ms
                thread_name,
                thread_id,
                process_name,
                is_main,
                weight_ns,
                weight_ns / 1000000.0,  # weight_ms
                function,
                backtrace
            ))

    # Insert samples
    conn.executemany("""
        INSERT INTO samples (timestamp_ns, timestamp_ms, thread_name, thread_id,
                            process_name, is_main_thread, weight_ns, weight_ms,
                            function, backtrace)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, samples)

    # Calculate main thread gaps
    main_samples = conn.execute("""
        SELECT timestamp_ms, function, backtrace
        FROM samples
        WHERE is_main_thread = 1
        ORDER BY timestamp_ms
    """).fetchall()

    gaps = []
    for i in range(1, len(main_samples)):
        prev_ts, prev_func, prev_bt = main_samples[i-1]
        curr_ts, curr_func, curr_bt = main_samples[i]
        gap_ms = curr_ts - prev_ts

        # Determine if idle
        before_idle = is_idle_backtrace(prev_func, prev_bt)
        after_idle = is_idle_backtrace(curr_func, curr_bt)
        is_idle = before_idle and after_idle

        gaps.append((gap_ms, curr_ts, prev_func, curr_func, prev_bt, curr_bt, is_idle))

    conn.executemany("""
        INSERT INTO main_thread_gaps (gap_ms, timestamp_ms, before_function,
                                      after_function, before_backtrace,
                                      after_backtrace, is_idle)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """, gaps)

    conn.commit()
    return len(samples)


def run_analysis_queries(conn: sqlite3.Connection, hang_threshold_ms: float,
                         stutter_threshold_ms: float, ignore_first_ms: float = 3000) -> dict:
    """Run analysis queries and return results."""

    # Get trace start time
    result = conn.execute("SELECT MIN(timestamp_ms) FROM samples WHERE timestamp_ms > 0").fetchone()
    trace_start = result[0] if result[0] else 0
    cutoff_ms = trace_start + ignore_first_ms

    # Total samples (all samples, for consistency with original)
    total_samples = conn.execute("SELECT COUNT(*) FROM samples").fetchone()[0]

    # Summary statistics from main thread gaps
    stats = conn.execute(f"""
        SELECT
            MAX(gap_ms) as max_gap,
            AVG(gap_ms) as avg_gap
        FROM main_thread_gaps
        WHERE timestamp_ms > {cutoff_ms} AND is_idle = 0
    """).fetchone()

    # Hangs (non-idle gaps >= threshold)
    hangs = conn.execute(f"""
        SELECT gap_ms, timestamp_ms, after_function, after_backtrace
        FROM main_thread_gaps
        WHERE timestamp_ms > {cutoff_ms}
          AND is_idle = 0
          AND gap_ms >= {hang_threshold_ms}
        ORDER BY gap_ms DESC
        LIMIT 10
    """).fetchall()

    # Stutters (non-idle gaps between stutter and hang thresholds)
    stutters = conn.execute(f"""
        SELECT gap_ms, timestamp_ms, after_function, after_backtrace
        FROM main_thread_gaps
        WHERE timestamp_ms > {cutoff_ms}
          AND is_idle = 0
          AND gap_ms >= {stutter_threshold_ms}
          AND gap_ms < {hang_threshold_ms}
        ORDER BY gap_ms DESC
        LIMIT 10
    """).fetchall()

    # P95 duration
    p95 = conn.execute(f"""
        SELECT gap_ms FROM main_thread_gaps
        WHERE timestamp_ms > {cutoff_ms} AND is_idle = 0
        ORDER BY gap_ms DESC
        LIMIT 1 OFFSET (
            SELECT CAST(COUNT(*) * 0.05 AS INTEGER)
            FROM main_thread_gaps
            WHERE timestamp_ms > {cutoff_ms} AND is_idle = 0
        )
    """).fetchone()

    # Filtered idle count
    filtered_idle = conn.execute(f"""
        SELECT COUNT(*) FROM main_thread_gaps
        WHERE timestamp_ms > {cutoff_ms}
          AND is_idle = 1
          AND gap_ms >= {hang_threshold_ms}
    """).fetchone()

    return {
        "total_samples": total_samples,
        "max_duration_ms": stats[0] or 0,
        "avg_duration_ms": round(stats[1] or 0, 1),
        "p95_duration_ms": p95[0] if p95 else 0,
        "hang_count": len(hangs),
        "stutter_count": len(stutters),
        "filtered_idle_count": filtered_idle[0] if filtered_idle else 0,
        "top_hangs": [
            {"duration_ms": h[0], "timestamp_ms": h[1], "function": h[2], "backtrace": h[3]}
            for h in hangs
        ],
        "top_stutters": [
            {"duration_ms": s[0], "timestamp_ms": s[1], "function": s[2]}
            for s in stutters
        ],
        "passed": len(hangs) == 0
    }


def print_report(results: dict, hang_threshold_ms: float, stutter_threshold_ms: float):
    """Print human-readable report."""
    print("\n" + "=" * 60)
    print("PERFORMANCE TRACE ANALYSIS (SQLite)")
    print("=" * 60)

    print(f"\n--- Summary ---")
    print(f"Total samples analyzed: {results['total_samples']}")
    print(f"Average duration: {results['avg_duration_ms']}ms")
    print(f"Max duration: {results['max_duration_ms']}ms")
    print(f"P95 duration: {results['p95_duration_ms']}ms")

    if results['filtered_idle_count'] > 0:
        print(f"Filtered idle periods: {results['filtered_idle_count']}")

    print(f"\n--- Hangs (>= {hang_threshold_ms}ms) ---")
    print(f"Count: {results['hang_count']}")
    for i, h in enumerate(results['top_hangs'][:5], 1):
        print(f"  {i}. {h['duration_ms']:.1f}ms - {h['function']}")

    print(f"\n--- Stutters ({stutter_threshold_ms}-{hang_threshold_ms}ms) ---")
    print(f"Count: {results['stutter_count']}")
    for i, s in enumerate(results['top_stutters'][:5], 1):
        print(f"  {i}. {s['duration_ms']:.1f}ms - {s['function']}")

    print("\n" + "=" * 60)
    if results['passed']:
        print("✅ PASS: No main thread hangs detected")
    else:
        print(f"❌ FAIL: Detected {results['hang_count']} main thread hang(s)")
    print("=" * 60 + "\n")


def interactive_shell(conn: sqlite3.Connection):
    """Open interactive SQL shell."""
    print("\nSQLite Interactive Shell - Trace Analysis Database")
    print("=" * 50)
    print("\nUseful queries:")
    print("  -- Top 10 longest main thread gaps:")
    print("  SELECT gap_ms, after_function FROM main_thread_gaps")
    print("  WHERE is_idle = 0 ORDER BY gap_ms DESC LIMIT 10;")
    print("")
    print("  -- Main thread samples grouped by function:")
    print("  SELECT function, COUNT(*) as samples, SUM(weight_ms) as total_ms")
    print("  FROM samples WHERE is_main_thread = 1")
    print("  GROUP BY function ORDER BY total_ms DESC LIMIT 20;")
    print("")
    print("  -- Find samples in a time range:")
    print("  SELECT timestamp_ms, function FROM samples")
    print("  WHERE is_main_thread = 1 AND timestamp_ms BETWEEN 4000 AND 5000;")
    print("")
    print("Type '.schema' to see tables, '.quit' to exit\n")

    conn.row_factory = sqlite3.Row
    while True:
        try:
            query = input("sql> ").strip()
            if not query:
                continue
            if query.lower() in ('.quit', '.exit', 'quit', 'exit'):
                break
            if query == '.schema':
                for row in conn.execute("SELECT sql FROM sqlite_master WHERE type='table'"):
                    print(row[0])
                continue
            if query == '.tables':
                for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
                    print(row[0])
                continue

            cursor = conn.execute(query)
            rows = cursor.fetchall()
            if rows:
                # Print header
                print(" | ".join(cursor.description[i][0] for i in range(len(cursor.description))))
                print("-" * 60)
                for row in rows:
                    print(" | ".join(str(v)[:50] if v else '' for v in row))
                print(f"({len(rows)} rows)")
        except KeyboardInterrupt:
            print()
            break
        except Exception as e:
            print(f"Error: {e}")


def main():
    parser = argparse.ArgumentParser(description="Analyze Instruments traces with SQLite")
    parser.add_argument("trace_file", help="Path to .trace file")
    parser.add_argument("--hang-threshold", type=float, default=250,
                       help="Hang threshold in ms (default: 250)")
    parser.add_argument("--stutter-threshold", type=float, default=100,
                       help="Stutter threshold in ms (default: 100)")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    parser.add_argument("--interactive", "-i", action="store_true",
                       help="Open interactive SQL shell")
    parser.add_argument("--db-only", action="store_true",
                       help="Only create database, don't analyze")
    parser.add_argument("--db-path", help="Path for SQLite database (default: temp file)")

    args = parser.parse_args()

    if not os.path.exists(args.trace_file):
        print(f"Error: Trace file not found: {args.trace_file}", file=sys.stderr)
        sys.exit(1)

    with tempfile.TemporaryDirectory() as tmpdir:
        # Export trace to XML
        print("Exporting trace data...", file=sys.stderr)
        xml_path = export_trace_to_xml(args.trace_file, tmpdir)
        if not xml_path or not os.path.exists(xml_path):
            print("Failed to export trace", file=sys.stderr)
            sys.exit(1)

        # Create database
        db_path = args.db_path or os.path.join(tmpdir, "trace.db")
        print(f"Creating database: {db_path}", file=sys.stderr)
        conn = create_database(db_path)

        # Parse XML into database
        sample_count = parse_xml_to_db(xml_path, conn)
        print(f"Loaded {sample_count} samples into database", file=sys.stderr)

        if args.db_only:
            print(f"Database created: {db_path}")
            return

        if args.interactive:
            interactive_shell(conn)
            return

        # Run analysis
        results = run_analysis_queries(conn, args.hang_threshold, args.stutter_threshold)
        results["trace_file"] = args.trace_file
        results["hang_threshold_ms"] = args.hang_threshold
        results["stutter_threshold_ms"] = args.stutter_threshold

        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print_report(results, args.hang_threshold, args.stutter_threshold)

        conn.close()
        sys.exit(0 if results['passed'] else 1)


if __name__ == "__main__":
    main()

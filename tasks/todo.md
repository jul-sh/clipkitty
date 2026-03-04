# Performance Investigation - Working Log

## Summary

**Date**: 2026-03-03
**Trace**: `perf_traces/perf_20260303_201928.trace`
**Result**: PASS - No true hangs (>= 250ms) detected after filtering idle periods

## Key Finding: Previous "Hangs" Were Idle Periods

The original analysis reported hangs of 1490ms and 351ms, but these were **misidentified**:
- Both gaps occurred when main thread was in `mach_msg2_trap` / `__CFRunLoopRun`
- These are normal idle waits between events, NOT blocking work
- The analysis script was fixed to distinguish idle vs active gaps

## Actual Performance Issues (Stutters 100-211ms)

After filtering idle periods, the real issues are:

| Duration | Timestamp | Root Cause | Call Stack |
|----------|-----------|------------|------------|
| 211ms | 8917ms | View drawing | `_recursive:displayRectIgnoringOpacity:` → `CA::Transaction::commit()` |
| 108ms | 6189ms | SwiftUI body | `ContentView.searchBar.getter` → `View.accessibilityIdentifier` |
| 107ms | 9702ms | State update | `GraphHost.asyncTransaction` → `debouncedSpinnerTask` |
| 106ms | 7306ms | TextView cleanup | `NSTextView dealloc` → `CA::Context::commit_transaction` |
| 102ms | 8684ms | Date formatting | `ClipboardItem.timeAgo.getter` → ICU number formatting |

## Root Causes Identified from Trace

### 1. Synchronous Icon Loading (MAIN BLOCKER)
**Location**: `ContentView.swift:813` in `metadataFooter(for:)`
**Call**: `NSWorkspace.shared.icon(forFile: appURL.path)`
**Evidence**: Sample at 8685ms shows `ISIconManager findOrRegisterIcon:` with barrier sync

This is called for EVERY visible item row during SwiftUI layout. The icon manager
uses `_dispatch_lane_barrier_sync_invoke_and_complete` which blocks the main thread.

### 2. SwiftUI Body Rebuilds (108ms, 106ms)
- `ContentView.searchBar.getter` triggers full body evaluation
- `State.projectedValue.getter` causes view updates
- Each keystroke triggers body rebuild cascade

### 3. Core Animation Transactions (211ms)
- 22ms of continuous SwiftUI layout work (8684-8706ms)
- Followed by 211ms waiting for CA commit
- View drawing in `displayRectIgnoringOpacity` is slow

### 4. Date Formatting (102ms)
- `ClipboardItem.timeAgo.getter` uses ICU RelativeDateTimeFormatter
- Called during list rendering for each visible item
- ICU number formatting is expensive

## Proposed Fixes (To Validate)

### Fix 1: Cache app icons (HIGHEST IMPACT)
**Location**: `ContentView.swift:813`
**Problem**: `NSWorkspace.shared.icon(forFile:)` called synchronously per row
**Solution**: Cache icons by bundle ID in a dictionary
**Expected impact**: Eliminate icon loading stutter during scrolling/typing

### Fix 2: Cache timeAgo computation
- RelativeDateTimeFormatter is already static (good)
- But timeAgo computed every render
- Could memoize for timestamps that haven't changed
- Expected impact: Reduce 102ms stutter

### Fix 3: Debounce SwiftUI state updates during typing
- Current debounce: 50ms in search
- Add debounce to spinner state updates
- Batch state changes to reduce body rebuilds
- Expected impact: Reduce 107-108ms stutters

## Next Steps

1. [ ] Implement Fix 1 (timeAgo caching) - lowest risk
2. [ ] Re-run perf test to validate improvement
3. [ ] If still stuttery, implement Fix 2
4. [ ] If still stuttery, implement Fix 3

## Success Criteria

- Max duration < 100ms during typing simulation
- P95 duration < 50ms
- No hangs >= 250ms (already achieved after idle filtering)

## Script Improvements Made

The `Scripts/analyze-trace.py` was enhanced to:
1. Properly resolve xctrace XML `ref` attributes for backtraces
2. Distinguish idle periods (mach_msg, CFRunLoop) from true hangs
3. Check both BEFORE and AFTER samples around gaps
4. Filter run loop housekeeping callbacks

## Alternative Tools Researched

| Tool | Description | Best For |
|------|-------------|----------|
| **ETTrace** | Flame chart profiler by Emerge Tools | Quick reliable profiling with visualization |
| **MTHawkeye** | Meitu's ANR detection toolkit | Production hang monitoring |
| **xctrace export** | Apple's CLI (what we use) | Custom analysis pipelines |
| **instrumentsToPprof** | Google's converter to pprof | Go/pprof workflow integration |

Our current approach (xctrace export + custom Python analysis) is appropriate for CI integration.
ETTrace could be useful for interactive debugging sessions.

#\!/usr/bin/env bash
# ==============================================================================
# Chaos Engineering Toolkit — Report Generator
# ==============================================================================
# Generates Markdown reports from experiment results. Tracks individual
# experiment outcomes and produces a combined summary report.
#
# Usage:
#   source lib/report_generator.sh
#   init_report_collector
#   record_experiment_result "pod-failure" "PASSED" "2024-01-01 10:00:00" "2024-01-01 10:05:00" "300"
#   generate_combined_report "./reports" "$start" "$end" 3 2 1
# ==============================================================================

# ---------------------------------------------------------------------------
# Report data storage (arrays for tracking multiple experiment results)
# ---------------------------------------------------------------------------
declare -a REPORT_EXPERIMENT_NAMES=()
declare -a REPORT_EXPERIMENT_STATUSES=()
declare -a REPORT_EXPERIMENT_START_TIMES=()
declare -a REPORT_EXPERIMENT_END_TIMES=()
declare -a REPORT_EXPERIMENT_DURATIONS=()

# ---------------------------------------------------------------------------
# Initialize the report collector (reset all arrays)
# ---------------------------------------------------------------------------
init_report_collector() {
    REPORT_EXPERIMENT_NAMES=()
    REPORT_EXPERIMENT_STATUSES=()
    REPORT_EXPERIMENT_START_TIMES=()
    REPORT_EXPERIMENT_END_TIMES=()
    REPORT_EXPERIMENT_DURATIONS=()
}

# ---------------------------------------------------------------------------
# Record a single experiment result
# ---------------------------------------------------------------------------
# Arguments:
#   $1 — experiment name (e.g., "pod-failure")
#   $2 — status ("PASSED" or "FAILED")
#   $3 — start time (e.g., "2024-01-01 10:00:00")
#   $4 — end time (e.g., "2024-01-01 10:05:00")
#   $5 — duration in seconds
# ---------------------------------------------------------------------------
record_experiment_result() {
    local name="${1:?Error: experiment name required}"
    local status="${2:?Error: status required}"
    local start_time="${3:?Error: start time required}"
    local end_time="${4:?Error: end time required}"
    local duration="${5:?Error: duration required}"

    REPORT_EXPERIMENT_NAMES+=("${name}")
    REPORT_EXPERIMENT_STATUSES+=("${status}")
    REPORT_EXPERIMENT_START_TIMES+=("${start_time}")
    REPORT_EXPERIMENT_END_TIMES+=("${end_time}")
    REPORT_EXPERIMENT_DURATIONS+=("${duration}")
}

# ---------------------------------------------------------------------------
# Format a status string with pass/fail indicator
# ---------------------------------------------------------------------------
format_status() {
    local status="${1}"
    case "${status}" in
        PASSED)          echo "PASSED" ;;
        FAILED)          echo "FAILED" ;;
        INTERRUPTED)     echo "INTERRUPTED" ;;
        FAILED_PRECHECKS) echo "FAILED (pre-checks)" ;;
        INJECTION_FAILED) echo "FAILED (injection)" ;;
        *)               echo "${status}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Check if a status represents a passing result
# ---------------------------------------------------------------------------
is_passing_status() {
    local status="${1}"
    [[ "${status}" == "PASSED" ]]
}

# ---------------------------------------------------------------------------
# Calculate total duration from individual durations
# ---------------------------------------------------------------------------
calculate_total_duration() {
    local total=0
    for duration in "${REPORT_EXPERIMENT_DURATIONS[@]}"; do
        total=$(( total + duration ))
    done
    echo "${total}"
}

# ---------------------------------------------------------------------------
# Format seconds into a human-readable duration string
# ---------------------------------------------------------------------------
format_duration() {
    local seconds="${1}"
    if [[ ${seconds} -ge 3600 ]]; then
        printf "%dh %dm %ds" $((seconds / 3600)) $(((seconds % 3600) / 60)) $((seconds % 60))
    elif [[ ${seconds} -ge 60 ]]; then
        printf "%dm %ds" $((seconds / 60)) $((seconds % 60))
    else
        printf "%ds" "${seconds}"
    fi
}

# ---------------------------------------------------------------------------
# Generate the combined Markdown report
# ---------------------------------------------------------------------------
# Arguments:
#   $1 — output directory
#   $2 — orchestration start time
#   $3 — orchestration end time
#   $4 — total experiment count
#   $5 — passed count
#   $6 — failed count
# ---------------------------------------------------------------------------
generate_combined_report() {
    local output_dir="${1:?Error: output directory required}"
    local run_start="${2:?Error: start time required}"
    local run_end="${3:?Error: end time required}"
    local total="${4:?Error: total count required}"
    local passed="${5:?Error: passed count required}"
    local failed="${6:?Error: failed count required}"

    local report_file="${output_dir}/combined-report-$(date '+%Y%m%d-%H%M%S').md"
    local total_duration
    total_duration="$(calculate_total_duration)"
    local overall_status="PASSED"
    if [[ ${failed} -gt 0 ]]; then
        overall_status="FAILED"
    fi

    mkdir -p "${output_dir}"

    cat > "${report_file}" <<REPORT
# Chaos Engineering — Combined Experiment Report

## Run Summary

| Field              | Value                              |
|--------------------|------------------------------------|
| **Overall Status** | ${overall_status}                  |
| **Start Time**     | ${run_start}                       |
| **End Time**       | ${run_end}                         |
| **Total Duration** | $(format_duration "${total_duration}") |
| **Experiments**    | ${total} total, ${passed} passed, ${failed} failed |

## Experiment Results

| # | Experiment | Status | Duration | Start | End |
|---|------------|--------|----------|-------|-----|
REPORT

    # Add each experiment result row
    for i in "${\!REPORT_EXPERIMENT_NAMES[@]}"; do
        local num=$((i + 1))
        local name="${REPORT_EXPERIMENT_NAMES[$i]}"
        local status
        status="$(format_status "${REPORT_EXPERIMENT_STATUSES[$i]}")"
        local duration
        duration="$(format_duration "${REPORT_EXPERIMENT_DURATIONS[$i]}")"
        local start="${REPORT_EXPERIMENT_START_TIMES[$i]}"
        local end="${REPORT_EXPERIMENT_END_TIMES[$i]}"

        echo "| ${num} | ${name} | ${status} | ${duration} | ${start} | ${end} |" >> "${report_file}"
    done

    cat >> "${report_file}" <<REPORT

## Detailed Observations

REPORT

    # Add per-experiment detail sections
    for i in "${\!REPORT_EXPERIMENT_NAMES[@]}"; do
        local name="${REPORT_EXPERIMENT_NAMES[$i]}"
        local status="${REPORT_EXPERIMENT_STATUSES[$i]}"
        local duration="${REPORT_EXPERIMENT_DURATIONS[$i]}"

        cat >> "${report_file}" <<SECTION
### ${name}

- **Status:** $(format_status "${status}")
- **Duration:** $(format_duration "${duration}")
$(if is_passing_status "${status}"; then
    echo "- **Observation:** System recovered to steady state within expected timeframe."
else
    echo "- **Observation:** System did NOT recover. Manual investigation recommended."
    echo "- **Action Required:** Review experiment logs and pod events for root cause."
fi)

SECTION
    done

    # Add footer
    cat >> "${report_file}" <<FOOTER
---

## Recommendations

$(if [[ ${failed} -gt 0 ]]; then
    echo "- Review failed experiments and identify root causes"
    echo "- Check pod resource limits and PodDisruptionBudgets"
    echo "- Verify HPA scaling thresholds are appropriate"
    echo "- Consider increasing recovery timeout for slow-recovering services"
else
    echo "- All experiments passed — system demonstrates good resilience"
    echo "- Consider increasing chaos intensity or adding new failure scenarios"
    echo "- Review Grafana dashboard for any latency spikes during experiments"
fi)

---
*Generated by Chaos Engineering Toolkit — $(date '+%Y-%m-%d %H:%M:%S')*
FOOTER

    echo -e "${BLUE:-}[INFO]${NC:-}  Combined report written to ${report_file}"
}

#\!/usr/bin/env bats
# ==============================================================================
# BATS Unit Tests — Report Generator
# ==============================================================================
# Tests the report generation library (lib/report_generator.sh):
#   - Report collector initialization
#   - Experiment result recording
#   - Status formatting
#   - Duration formatting
#   - Combined report generation (output format, pass/fail detection)
# ==============================================================================

setup() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d)"

    source "${PROJECT_ROOT}/lib/report_generator.sh"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Initialization tests
# ---------------------------------------------------------------------------
@test "init_report_collector resets all arrays" {
    # Add some data first
    REPORT_EXPERIMENT_NAMES=("test1" "test2")
    REPORT_EXPERIMENT_STATUSES=("PASSED" "FAILED")

    init_report_collector

    [ ${#REPORT_EXPERIMENT_NAMES[@]} -eq 0 ]
    [ ${#REPORT_EXPERIMENT_STATUSES[@]} -eq 0 ]
    [ ${#REPORT_EXPERIMENT_START_TIMES[@]} -eq 0 ]
    [ ${#REPORT_EXPERIMENT_END_TIMES[@]} -eq 0 ]
    [ ${#REPORT_EXPERIMENT_DURATIONS[@]} -eq 0 ]
}

# ---------------------------------------------------------------------------
# Result recording tests
# ---------------------------------------------------------------------------
@test "record_experiment_result stores all fields" {
    init_report_collector
    record_experiment_result "pod-failure" "PASSED" "2024-01-01 10:00:00" "2024-01-01 10:03:00" "180"

    [ "${REPORT_EXPERIMENT_NAMES[0]}" = "pod-failure" ]
    [ "${REPORT_EXPERIMENT_STATUSES[0]}" = "PASSED" ]
    [ "${REPORT_EXPERIMENT_START_TIMES[0]}" = "2024-01-01 10:00:00" ]
    [ "${REPORT_EXPERIMENT_END_TIMES[0]}" = "2024-01-01 10:03:00" ]
    [ "${REPORT_EXPERIMENT_DURATIONS[0]}" = "180" ]
}

@test "record_experiment_result appends multiple results" {
    init_report_collector
    record_experiment_result "pod-failure" "PASSED" "10:00" "10:03" "180"
    record_experiment_result "network-chaos" "FAILED" "10:05" "10:10" "300"
    record_experiment_result "node-drain" "PASSED" "10:15" "10:20" "300"

    [ ${#REPORT_EXPERIMENT_NAMES[@]} -eq 3 ]
    [ "${REPORT_EXPERIMENT_NAMES[1]}" = "network-chaos" ]
    [ "${REPORT_EXPERIMENT_STATUSES[1]}" = "FAILED" ]
}

# ---------------------------------------------------------------------------
# Status formatting tests
# ---------------------------------------------------------------------------
@test "format_status returns correct string for PASSED" {
    run format_status "PASSED"
    [ "$output" = "PASSED" ]
}

@test "format_status returns correct string for FAILED" {
    run format_status "FAILED"
    [ "$output" = "FAILED" ]
}

@test "format_status returns correct string for INTERRUPTED" {
    run format_status "INTERRUPTED"
    [ "$output" = "INTERRUPTED" ]
}

@test "format_status returns correct string for FAILED_PRECHECKS" {
    run format_status "FAILED_PRECHECKS"
    [ "$output" = "FAILED (pre-checks)" ]
}

@test "format_status returns correct string for INJECTION_FAILED" {
    run format_status "INJECTION_FAILED"
    [ "$output" = "FAILED (injection)" ]
}

@test "format_status passes through unknown status" {
    run format_status "CUSTOM_STATUS"
    [ "$output" = "CUSTOM_STATUS" ]
}

# ---------------------------------------------------------------------------
# Pass/fail detection tests
# ---------------------------------------------------------------------------
@test "is_passing_status returns 0 for PASSED" {
    run is_passing_status "PASSED"
    [ "$status" -eq 0 ]
}

@test "is_passing_status returns 1 for FAILED" {
    run is_passing_status "FAILED"
    [ "$status" -eq 1 ]
}

@test "is_passing_status returns 1 for INTERRUPTED" {
    run is_passing_status "INTERRUPTED"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Duration calculation tests
# ---------------------------------------------------------------------------
@test "calculate_total_duration sums all durations" {
    init_report_collector
    REPORT_EXPERIMENT_DURATIONS=(60 120 180)

    run calculate_total_duration
    [ "$output" = "360" ]
}

@test "calculate_total_duration returns 0 for empty array" {
    init_report_collector
    run calculate_total_duration
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Duration formatting tests
# ---------------------------------------------------------------------------
@test "format_duration formats seconds only" {
    run format_duration 45
    [ "$output" = "45s" ]
}

@test "format_duration formats minutes and seconds" {
    run format_duration 125
    [ "$output" = "2m 5s" ]
}

@test "format_duration formats hours minutes seconds" {
    run format_duration 3723
    [ "$output" = "1h 2m 3s" ]
}

@test "format_duration handles zero" {
    run format_duration 0
    [ "$output" = "0s" ]
}

# ---------------------------------------------------------------------------
# Combined report generation tests
# ---------------------------------------------------------------------------
@test "generate_combined_report creates a valid markdown file" {
    init_report_collector
    record_experiment_result "pod-failure" "PASSED" "2024-01-01 10:00:00" "2024-01-01 10:03:00" "180"
    record_experiment_result "network-chaos" "PASSED" "2024-01-01 10:05:00" "2024-01-01 10:08:00" "180"

    generate_combined_report "${TEST_TMPDIR}" "2024-01-01 10:00:00" "2024-01-01 10:10:00" "2" "2" "0"

    local report_file
    report_file="$(ls "${TEST_TMPDIR}"/combined-report-*.md 2>/dev/null | head -1)"
    [ -f "${report_file}" ]

    local content
    content="$(cat "${report_file}")"
    [[ "${content}" == *"# Chaos Engineering"* ]]
    [[ "${content}" == *"pod-failure"* ]]
    [[ "${content}" == *"network-chaos"* ]]
}

@test "generate_combined_report shows PASSED overall when all pass" {
    init_report_collector
    record_experiment_result "pod-failure" "PASSED" "10:00" "10:03" "180"

    generate_combined_report "${TEST_TMPDIR}" "10:00" "10:05" "1" "1" "0"

    local content
    content="$(cat "${TEST_TMPDIR}"/combined-report-*.md)"
    [[ "${content}" == *"PASSED"* ]]
    [[ "${content}" == *"good resilience"* ]]
}

@test "generate_combined_report shows FAILED overall when any fail" {
    init_report_collector
    record_experiment_result "pod-failure" "PASSED" "10:00" "10:03" "180"
    record_experiment_result "network-chaos" "FAILED" "10:05" "10:10" "300"

    generate_combined_report "${TEST_TMPDIR}" "10:00" "10:15" "2" "1" "1"

    local content
    content="$(cat "${TEST_TMPDIR}"/combined-report-*.md)"
    [[ "${content}" == *"FAILED"* ]]
    [[ "${content}" == *"Review failed experiments"* ]]
}

@test "generate_combined_report includes experiment table rows" {
    init_report_collector
    record_experiment_result "pod-failure" "PASSED" "10:00" "10:03" "180"
    record_experiment_result "network-chaos" "FAILED" "10:05" "10:10" "300"
    record_experiment_result "node-drain" "PASSED" "10:15" "10:20" "300"

    generate_combined_report "${TEST_TMPDIR}" "10:00" "10:25" "3" "2" "1"

    local content
    content="$(cat "${TEST_TMPDIR}"/combined-report-*.md)"
    # Check table has 3 data rows (grep for numbered rows)
    local row_count
    row_count="$(echo "${content}" | grep -c '| [0-9]')"
    [ "${row_count}" -eq 3 ]
}

@test "generate_combined_report creates output directory if missing" {
    local nested_dir="${TEST_TMPDIR}/deep/nested/reports"
    init_report_collector
    record_experiment_result "test" "PASSED" "10:00" "10:01" "60"

    generate_combined_report "${nested_dir}" "10:00" "10:01" "1" "1" "0"

    [ -d "${nested_dir}" ]
    [ -f "${nested_dir}"/combined-report-*.md ]
}

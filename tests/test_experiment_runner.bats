#\!/usr/bin/env bats
# ==============================================================================
# BATS Unit Tests — Experiment Runner
# ==============================================================================
# Tests core functions from lib/experiment_runner.sh:
#   - Logging helpers
#   - Config parsing (experiment variables)
#   - Steady-state validation logic
#   - Cleanup trap behavior
# ==============================================================================

# ---------------------------------------------------------------------------
# Test setup — create mock environment
# ---------------------------------------------------------------------------
setup() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."

    # Create a temp directory for test artifacts
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d)"

    # Mock kubectl to avoid requiring a real cluster
    export PATH="${TEST_TMPDIR}/bin:${PATH}"
    mkdir -p "${TEST_TMPDIR}/bin"

    # Default mock kubectl — returns success
    cat > "${TEST_TMPDIR}/bin/kubectl" << 'MOCK'
#\!/usr/bin/env bash
case "$*" in
    "cluster-info")
        echo "Kubernetes control plane is running at https://127.0.0.1:6443"
        exit 0
        ;;
    "get namespace"*)
        echo "NAME     STATUS   AGE"
        echo "default  Active   10d"
        exit 0
        ;;
    "get deployment"*)
        echo "NAME        READY   UP-TO-DATE   AVAILABLE   AGE"
        echo "sample-app  3/3     3            3           5d"
        exit 0
        ;;
    *"jsonpath='{.status.readyReplicas}'"*|*"jsonpath={.status.readyReplicas}"*)
        echo "3"
        exit 0
        ;;
    *"jsonpath='{.spec.unschedulable}'"*|*"jsonpath={.spec.unschedulable}"*)
        echo "false"
        exit 0
        ;;
    "get pods"*)
        echo "sample-app-abc123 sample-app-def456 sample-app-ghi789"
        exit 0
        ;;
    "rollout status"*)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK
    chmod +x "${TEST_TMPDIR}/bin/kubectl"

    # Mock curl for health checks
    cat > "${TEST_TMPDIR}/bin/curl" << 'MOCK'
#\!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"%{http_code}"* ]]; then
        echo "200"
        exit 0
    fi
    if [[ "$arg" == *"%{time_total}"* ]]; then
        echo "0.045"
        exit 0
    fi
done
echo "OK"
exit 0
MOCK
    chmod +x "${TEST_TMPDIR}/bin/curl"

    # Mock bc for arithmetic
    if \! command -v bc &>/dev/null; then
        cat > "${TEST_TMPDIR}/bin/bc" << 'MOCK'
#\!/usr/bin/env bash
python3 -c "print(eval(input()))" 2>/dev/null || echo "0"
MOCK
        chmod +x "${TEST_TMPDIR}/bin/bc"
    fi

    # Set experiment variables
    export EXPERIMENT_NAME="test-experiment"
    export EXPERIMENT_DIR="${TEST_TMPDIR}"
    export TARGET_NAMESPACE="default"
    export TARGET_DEPLOYMENT="sample-app"
    export HEALTH_ENDPOINT=""
    export RECOVERY_TIMEOUT="10"
    export POLL_INTERVAL="1"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Logging helper tests
# ---------------------------------------------------------------------------
@test "log_info outputs INFO tag with message" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run log_info "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"Test message"* ]]
}

@test "log_success outputs PASS tag with message" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run log_success "All checks passed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[PASS]"* ]]
    [[ "$output" == *"All checks passed"* ]]
}

@test "log_error outputs FAIL tag with message" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run log_error "Something went wrong"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"Something went wrong"* ]]
}

@test "log_warn outputs WARN tag with message" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run log_warn "Potential issue"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"Potential issue"* ]]
}

@test "log_step outputs STEP tag with message" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run log_step "Running phase 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STEP]"* ]]
    [[ "$output" == *"Running phase 1"* ]]
}

# ---------------------------------------------------------------------------
# Steady-state capture tests
# ---------------------------------------------------------------------------
@test "capture_pod_count records baseline from kubectl" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    capture_pod_count "default" "sample-app"
    [ "${BASELINE_POD_COUNT}" = "3" ]
}

@test "capture_pod_count handles missing deployment gracefully" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run capture_pod_count "default" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping pod count"* ]]
}

@test "validate_pod_count passes when current matches baseline" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    BASELINE_POD_COUNT="3"
    run validate_pod_count "default" "sample-app"
    [ "$status" -eq 0 ]
}

@test "validate_pod_count fails when current is below baseline" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    BASELINE_POD_COUNT="5"

    # Override kubectl to return lower count
    cat > "${TEST_TMPDIR}/bin/kubectl" << 'MOCK'
#\!/usr/bin/env bash
echo "2"
exit 0
MOCK
    chmod +x "${TEST_TMPDIR}/bin/kubectl"

    run validate_pod_count "default" "sample-app"
    [ "$status" -eq 1 ]
}

@test "validate_pod_count skips when no deployment specified" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    BASELINE_POD_COUNT=""
    run validate_pod_count "default" ""
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Pre-checks tests
# ---------------------------------------------------------------------------
@test "run_prechecks succeeds with reachable cluster" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run run_prechecks
    [ "$status" -eq 0 ]
    [[ "$output" == *"All pre-checks passed"* ]]
}

@test "run_prechecks fails when cluster is unreachable" {
    # Override kubectl to fail on cluster-info
    cat > "${TEST_TMPDIR}/bin/kubectl" << 'MOCK'
#\!/usr/bin/env bash
if [[ "$1" == "cluster-info" ]]; then
    exit 1
fi
exit 0
MOCK
    chmod +x "${TEST_TMPDIR}/bin/kubectl"

    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    run run_prechecks
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot connect"* ]]
}

# ---------------------------------------------------------------------------
# Report generation tests
# ---------------------------------------------------------------------------
@test "generate_report creates report file with correct status" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    export REPORT_DIR="${TEST_TMPDIR}/reports"
    START_TIME="2024-01-01 10:00:00"
    END_TIME="2024-01-01 10:05:00"

    generate_report "PASSED" "300"

    [ -f "${TEST_TMPDIR}/reports/${EXPERIMENT_NAME}"*.md ]
    local report_content
    report_content="$(cat "${TEST_TMPDIR}/reports/${EXPERIMENT_NAME}"*.md)"
    [[ "${report_content}" == *"PASSED"* ]]
    [[ "${report_content}" == *"confirmed"* ]]
}

@test "generate_report shows rejection for failed experiments" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    export REPORT_DIR="${TEST_TMPDIR}/reports"
    START_TIME="2024-01-01 10:00:00"
    END_TIME="2024-01-01 10:05:00"

    generate_report "FAILED" "120"

    local report_content
    report_content="$(cat "${TEST_TMPDIR}/reports/${EXPERIMENT_NAME}"*.md)"
    [[ "${report_content}" == *"FAILED"* ]]
    [[ "${report_content}" == *"rejected"* ]]
}

# ---------------------------------------------------------------------------
# Config / global state tests
# ---------------------------------------------------------------------------
@test "EXPERIMENT_STATUS initializes to NOT_RUN" {
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    [ "${EXPERIMENT_STATUS}" = "NOT_RUN" ]
}

@test "default EXPERIMENT_NAME is 'unknown' when not set" {
    unset EXPERIMENT_NAME
    source "${PROJECT_ROOT}/lib/experiment_runner.sh"
    [ "${EXPERIMENT_NAME}" = "unknown" ]
}

#!/usr/bin/env bash
# ==============================================================================
# Chaos Engineering Toolkit — Experiment Runner Framework
# ==============================================================================
# Provides a structured lifecycle for running chaos experiments:
#   1. Pre-checks    — validate cluster connectivity and prerequisites
#   2. Steady-state  — capture baseline metrics before injection
#   3. Inject        — execute the chaos action (provided by each experiment)
#   4. Validate      — compare current state against steady-state baseline
#   5. Rollback      — restore system to pre-experiment state
#   6. Report        — generate a summary report of the experiment run
#
# Usage:
#   source lib/experiment_runner.sh
#   Then call `run_experiment` from your experiment script.
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC}  $(date '+%H:%M:%S') $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%H:%M:%S') $*"; }

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
EXPERIMENT_NAME="${EXPERIMENT_NAME:-unknown}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:-.}"
REPORT_DIR="${EXPERIMENT_DIR}/reports"
REPORT_FILE=""
START_TIME=""
END_TIME=""
EXPERIMENT_STATUS="NOT_RUN"

# ---------------------------------------------------------------------------
# Pre-checks — validate that the cluster is reachable and prerequisites exist
# ---------------------------------------------------------------------------
run_prechecks() {
    log_step "Running pre-checks..."

    # Check kubectl connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Is your kubeconfig set?"
        return 1
    fi
    log_success "Cluster is reachable"

    # Check that the target namespace exists
    local namespace="${TARGET_NAMESPACE:-default}"
    if ! kubectl get namespace "${namespace}" &>/dev/null; then
        log_error "Namespace '${namespace}' does not exist"
        return 1
    fi
    log_success "Namespace '${namespace}' exists"

    # Check that the target deployment exists (if specified)
    if [[ -n "${TARGET_DEPLOYMENT:-}" ]]; then
        if ! kubectl get deployment "${TARGET_DEPLOYMENT}" -n "${namespace}" &>/dev/null; then
            log_error "Deployment '${TARGET_DEPLOYMENT}' not found in namespace '${namespace}'"
            return 1
        fi
        log_success "Deployment '${TARGET_DEPLOYMENT}' found"
    fi

    # Run experiment-specific pre-checks if defined
    if declare -f experiment_prechecks &>/dev/null; then
        experiment_prechecks
    fi

    log_success "All pre-checks passed"
}

# ---------------------------------------------------------------------------
# Steady-state capture — delegate to steady_state.sh helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/steady_state.sh
source "${SCRIPT_DIR}/steady_state.sh"

capture_steady_state() {
    log_step "Capturing steady-state baseline..."
    local namespace="${TARGET_NAMESPACE:-default}"

    capture_pod_count "${namespace}" "${TARGET_DEPLOYMENT:-}"
    capture_endpoint_health "${HEALTH_ENDPOINT:-}"
    capture_response_time "${HEALTH_ENDPOINT:-}"

    # Run experiment-specific steady-state capture if defined
    if declare -f experiment_capture_steady_state &>/dev/null; then
        experiment_capture_steady_state
    fi

    log_success "Steady-state baseline captured"
}

# ---------------------------------------------------------------------------
# Validation — compare current state to baseline
# ---------------------------------------------------------------------------
validate_steady_state() {
    log_step "Validating steady-state recovery..."
    local namespace="${TARGET_NAMESPACE:-default}"
    local recovery_timeout="${RECOVERY_TIMEOUT:-120}"
    local poll_interval="${POLL_INTERVAL:-5}"
    local elapsed=0
    local recovered=false

    while [[ ${elapsed} -lt ${recovery_timeout} ]]; do
        local failures=0

        # Validate pod count
        if ! validate_pod_count "${namespace}" "${TARGET_DEPLOYMENT:-}"; then
            ((failures++)) || true
        fi

        # Validate endpoint health
        if [[ -n "${HEALTH_ENDPOINT:-}" ]]; then
            if ! validate_endpoint_health "${HEALTH_ENDPOINT}"; then
                ((failures++)) || true
            fi
        fi

        # Run experiment-specific validation if defined
        if declare -f experiment_validate &>/dev/null; then
            if ! experiment_validate; then
                ((failures++)) || true
            fi
        fi

        if [[ ${failures} -eq 0 ]]; then
            recovered=true
            break
        fi

        log_info "Steady-state not yet recovered (${elapsed}s / ${recovery_timeout}s). Retrying in ${poll_interval}s..."
        sleep "${poll_interval}"
        elapsed=$((elapsed + poll_interval))
    done

    if [[ "${recovered}" == "true" ]]; then
        log_success "Steady-state recovered after ${elapsed}s"
        return 0
    else
        log_error "Steady-state NOT recovered within ${recovery_timeout}s"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Rollback — restore the system to its pre-experiment state
# ---------------------------------------------------------------------------
run_rollback() {
    log_step "Running rollback..."

    # Run experiment-specific rollback if defined
    if declare -f experiment_rollback &>/dev/null; then
        experiment_rollback
    else
        log_warn "No experiment-specific rollback defined"
    fi

    log_success "Rollback complete"
}

# ---------------------------------------------------------------------------
# Report generation — produce a markdown summary of the experiment
# ---------------------------------------------------------------------------
generate_report() {
    local status="${1:-UNKNOWN}"
    local duration="${2:-0}"

    mkdir -p "${REPORT_DIR}"
    REPORT_FILE="${REPORT_DIR}/${EXPERIMENT_NAME}-$(date '+%Y%m%d-%H%M%S').md"

    cat > "${REPORT_FILE}" <<REPORT
# Chaos Experiment Report: ${EXPERIMENT_NAME}

| Field             | Value                              |
|-------------------|------------------------------------|
| **Experiment**    | ${EXPERIMENT_NAME}                 |
| **Status**        | ${status}                          |
| **Start Time**    | ${START_TIME}                      |
| **End Time**      | ${END_TIME}                        |
| **Duration**      | ${duration}s                       |
| **Namespace**     | ${TARGET_NAMESPACE:-default}       |
| **Deployment**    | ${TARGET_DEPLOYMENT:-N/A}          |

## Steady-State Baseline

| Metric            | Baseline Value                     |
|-------------------|------------------------------------|
| Pod Count         | ${BASELINE_POD_COUNT:-N/A}         |
| Endpoint Health   | ${BASELINE_HEALTH_STATUS:-N/A}     |
| Response Time     | ${BASELINE_RESPONSE_TIME:-N/A} ms  |

## Result

$(if [[ "${status}" == "PASSED" ]]; then
    echo "The system recovered to its steady state within the expected timeframe."
    echo "The experiment hypothesis was **confirmed**."
else
    echo "The system did **NOT** recover to its steady state within the expected timeframe."
    echo "The experiment hypothesis was **rejected**. Investigation required."
fi)

## Notes

- Recovery timeout: ${RECOVERY_TIMEOUT:-120}s
- Poll interval: ${POLL_INTERVAL:-5}s
REPORT

    log_info "Report written to ${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# Cleanup trap — ensures rollback runs even on unexpected exit
# ---------------------------------------------------------------------------
_cleanup_on_exit() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && "${EXPERIMENT_STATUS}" == "RUNNING" ]]; then
        log_warn "Experiment interrupted (exit code ${exit_code}). Running emergency rollback..."
        run_rollback
        END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
        generate_report "INTERRUPTED" "0"
    fi
}

# ---------------------------------------------------------------------------
# Main experiment lifecycle
# ---------------------------------------------------------------------------
# Each experiment script must define:
#   experiment_inject()   — the chaos action to execute
#
# Optional overrides:
#   experiment_prechecks()              — additional pre-flight checks
#   experiment_capture_steady_state()   — additional baseline metrics
#   experiment_validate()               — additional validation checks
#   experiment_rollback()               — restore actions after experiment
# ---------------------------------------------------------------------------
run_experiment() {
    trap _cleanup_on_exit EXIT

    echo ""
    echo "============================================================"
    echo "  Chaos Experiment: ${EXPERIMENT_NAME}"
    echo "  Started at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo ""

    START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
    local start_epoch
    start_epoch="$(date '+%s')"
    EXPERIMENT_STATUS="RUNNING"

    # Phase 1: Pre-checks
    if ! run_prechecks; then
        EXPERIMENT_STATUS="FAILED_PRECHECKS"
        END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
        generate_report "FAILED_PRECHECKS" "0"
        log_error "Experiment aborted: pre-checks failed"
        return 1
    fi

    # Phase 2: Capture steady-state baseline
    capture_steady_state

    # Phase 3: Inject chaos
    log_step "Injecting chaos..."
    if ! experiment_inject; then
        log_error "Chaos injection failed"
        run_rollback
        END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
        local duration=$(( $(date '+%s') - start_epoch ))
        generate_report "INJECTION_FAILED" "${duration}"
        return 1
    fi
    log_success "Chaos injected"

    # Phase 4: Wait for observation period (if configured)
    local observation_period="${OBSERVATION_PERIOD:-0}"
    if [[ ${observation_period} -gt 0 ]]; then
        log_info "Observing for ${observation_period}s..."
        sleep "${observation_period}"
    fi

    # Phase 5: Validate steady-state recovery
    local validation_result=0
    if ! validate_steady_state; then
        validation_result=1
    fi

    # Phase 6: Rollback
    run_rollback

    # Phase 7: Generate report
    END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
    local duration=$(( $(date '+%s') - start_epoch ))

    if [[ ${validation_result} -eq 0 ]]; then
        EXPERIMENT_STATUS="PASSED"
        generate_report "PASSED" "${duration}"
        echo ""
        log_success "============================================================"
        log_success "  Experiment PASSED — system recovered to steady state"
        log_success "============================================================"
    else
        EXPERIMENT_STATUS="FAILED"
        generate_report "FAILED" "${duration}"
        echo ""
        log_error "============================================================"
        log_error "  Experiment FAILED — system did NOT recover"
        log_error "============================================================"
        return 1
    fi
}

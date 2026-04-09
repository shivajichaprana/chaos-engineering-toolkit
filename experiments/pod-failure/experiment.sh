#!/usr/bin/env bash
# ==============================================================================
# Chaos Experiment: Pod Failure
# ==============================================================================
# Hypothesis:
#   When random pods in a deployment are deleted, Kubernetes will automatically
#   reschedule replacement pods and the service will recover within the defined
#   SLA (recovery timeout). The health endpoint will remain reachable throughout
#   the experiment (brief interruption is acceptable, full recovery is required).
#
# Procedure:
#   1. Validate cluster connectivity and target deployment existence
#   2. Capture steady-state: pod count, endpoint health, response time
#   3. Select N random pods from the target deployment
#   4. Delete the selected pods (force-delete with grace period)
#   5. Poll until pod count recovers to baseline and endpoint is healthy
#   6. Roll back (no-op — Kubernetes handles rescheduling automatically)
#   7. Generate a Markdown report with pass/fail status
#
# Usage:
#   ./experiments/pod-failure/experiment.sh
#   ./experiments/pod-failure/experiment.sh --config experiments/pod-failure/config.yaml
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths relative to the repository root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Source the experiment runner framework
# ---------------------------------------------------------------------------
# shellcheck source=lib/experiment_runner.sh
source "${REPO_ROOT}/lib/experiment_runner.sh"

# ---------------------------------------------------------------------------
# Load experiment configuration
# ---------------------------------------------------------------------------
CONFIG_FILE="${1:-${SCRIPT_DIR}/config.yaml}"

parse_config() {
    # Parse YAML config using simple grep/sed (no external YAML parser needed)
    # Falls back to defaults if config file is missing or fields are absent
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_warn "Config file not found: ${CONFIG_FILE}. Using defaults."
        return 0
    fi

    log_info "Loading config from ${CONFIG_FILE}"

    TARGET_DEPLOYMENT=$(grep -E '^\s*target_deployment:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    TARGET_NAMESPACE=$(grep -E '^\s*namespace:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    PODS_TO_KILL=$(grep -E '^\s*pods_to_kill:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    RECOVERY_TIMEOUT=$(grep -E '^\s*recovery_timeout:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    HEALTH_ENDPOINT=$(grep -E '^\s*health_endpoint:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    GRACE_PERIOD=$(grep -E '^\s*grace_period:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    OBSERVATION_PERIOD=$(grep -E '^\s*observation_period:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    POLL_INTERVAL=$(grep -E '^\s*poll_interval:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
}

# Apply defaults
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-sample-app}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-chaos-testing}"
PODS_TO_KILL="${PODS_TO_KILL:-1}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-120}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-}"
GRACE_PERIOD="${GRACE_PERIOD:-0}"
OBSERVATION_PERIOD="${OBSERVATION_PERIOD:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Parse config (overrides defaults if values are present)
parse_config

# Re-apply defaults for any empty values after config parsing
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-sample-app}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-chaos-testing}"
PODS_TO_KILL="${PODS_TO_KILL:-1}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-120}"
GRACE_PERIOD="${GRACE_PERIOD:-0}"
OBSERVATION_PERIOD="${OBSERVATION_PERIOD:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Set experiment metadata used by the runner framework
EXPERIMENT_NAME="pod-failure"
EXPERIMENT_DIR="${SCRIPT_DIR}"

# Track which pods we killed (for reporting)
KILLED_PODS=()

# ---------------------------------------------------------------------------
# Experiment-specific pre-checks
# ---------------------------------------------------------------------------
experiment_prechecks() {
    # Verify the deployment has enough replicas to kill
    local available_pods
    available_pods=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)

    if [[ "${available_pods}" -lt "${PODS_TO_KILL}" ]]; then
        log_error "Not enough running pods (${available_pods}) to kill ${PODS_TO_KILL}"
        return 1
    fi

    log_success "Deployment has ${available_pods} running pods (will kill ${PODS_TO_KILL})"
}

# ---------------------------------------------------------------------------
# Chaos injection — delete random pods from the target deployment
# ---------------------------------------------------------------------------
experiment_inject() {
    log_info "Selecting ${PODS_TO_KILL} random pod(s) from deployment '${TARGET_DEPLOYMENT}'..."

    # Get all running pod names for the target deployment
    local all_pods
    all_pods=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    # Shuffle and select the requested number of pods
    local selected_pods
    selected_pods=$(echo "${all_pods}" | tr ' ' '\n' | shuf | head -n "${PODS_TO_KILL}")

    if [[ -z "${selected_pods}" ]]; then
        log_error "No pods selected for deletion"
        return 1
    fi

    # Delete each selected pod
    for pod in ${selected_pods}; do
        log_info "Deleting pod: ${pod} (grace period: ${GRACE_PERIOD}s)"
        kubectl delete pod "${pod}" \
            -n "${TARGET_NAMESPACE}" \
            --grace-period="${GRACE_PERIOD}" \
            --wait=false 2>/dev/null

        KILLED_PODS+=("${pod}")
        log_success "Pod '${pod}' marked for deletion"
    done

    log_info "Deleted ${#KILLED_PODS[@]} pod(s). Kubernetes should reschedule replacements."
}

# ---------------------------------------------------------------------------
# Experiment-specific validation — verify new pods are running
# ---------------------------------------------------------------------------
experiment_validate() {
    # Check that none of the killed pods still exist (they should be replaced)
    local stale_count=0

    for pod in "${KILLED_PODS[@]}"; do
        if kubectl get pod "${pod}" -n "${TARGET_NAMESPACE}" &>/dev/null; then
            local phase
            phase=$(kubectl get pod "${pod}" -n "${TARGET_NAMESPACE}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [[ "${phase}" == "Running" ]]; then
                log_warn "Killed pod '${pod}' is still running"
                ((stale_count++)) || true
            fi
        fi
    done

    if [[ ${stale_count} -gt 0 ]]; then
        log_warn "${stale_count} killed pod(s) still running"
        return 1
    fi

    log_success "All killed pods have been replaced"
    return 0
}

# ---------------------------------------------------------------------------
# Rollback — Kubernetes handles pod rescheduling automatically
# ---------------------------------------------------------------------------
experiment_rollback() {
    log_info "No manual rollback needed — Kubernetes ReplicaSet handles pod recreation"

    # Wait for deployment to stabilize
    if ! wait_for_pods_ready "${TARGET_DEPLOYMENT}" "${TARGET_NAMESPACE}" 60; then
        log_warn "Deployment may not be fully stable after rollback wait"
    fi
}

# ---------------------------------------------------------------------------
# Run the experiment
# ---------------------------------------------------------------------------
run_experiment

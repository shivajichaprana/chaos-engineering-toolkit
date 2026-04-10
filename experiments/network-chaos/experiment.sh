#\!/usr/bin/env bash
# ==============================================================================
# Chaos Experiment: Network Latency Injection
# ==============================================================================
# Hypothesis:
#   When network latency is injected into target pods using tc (traffic control),
#   the application will continue to serve requests within the acceptable
#   response time threshold. Circuit breakers, timeouts, and retry mechanisms
#   should activate to prevent cascading failures. After latency injection is
#   removed, response times should return to baseline within the recovery window.
#
# Procedure:
#   1. Validate cluster connectivity and target deployment existence
#   2. Capture steady-state: pod count, endpoint health, baseline response time
#   3. Deploy tc-injector DaemonSet (privileged container for tc manipulation)
#   4. Inject latency via tc qdisc rules on target pods' network interfaces
#   5. Probe the health endpoint repeatedly to measure response time degradation
#   6. Validate that response times stay below the acceptable threshold
#   7. Remove tc rules (rollback) and verify response time recovery
#   8. Generate a Markdown report with pass/fail status
#
# Usage:
#   ./experiments/network-chaos/experiment.sh
#   ./experiments/network-chaos/experiment.sh --config experiments/network-chaos/config.yaml
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
    if [[ \! -f "${CONFIG_FILE}" ]]; then
        log_warn "Config file not found: ${CONFIG_FILE}. Using defaults."
        return 0
    fi

    log_info "Loading config from ${CONFIG_FILE}"

    TARGET_DEPLOYMENT=$(grep -E '^\s*target_deployment:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    TARGET_NAMESPACE=$(grep -E '^\s*namespace:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    LATENCY_MS=$(grep -E '^\s*latency_ms:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    JITTER_MS=$(grep -E '^\s*jitter_ms:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    CHAOS_DURATION=$(grep -E '^\s*chaos_duration:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    ACCEPTABLE_RESPONSE_TIME_MS=$(grep -E '^\s*acceptable_response_time_ms:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    HEALTH_ENDPOINT=$(grep -E '^\s*health_endpoint:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    PROBE_COUNT=$(grep -E '^\s*probe_count:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    RECOVERY_TIMEOUT=$(grep -E '^\s*recovery_timeout:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    OBSERVATION_PERIOD=$(grep -E '^\s*observation_period:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    POLL_INTERVAL=$(grep -E '^\s*poll_interval:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    TARGET_INTERFACE=$(grep -E '^\s*target_interface:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
    PACKET_LOSS_PERCENT=$(grep -E '^\s*packet_loss_percent:' "${CONFIG_FILE}" \
        | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" || echo "")
}

# Apply defaults
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-sample-app}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-chaos-testing}"
LATENCY_MS="${LATENCY_MS:-200}"
JITTER_MS="${JITTER_MS:-50}"
CHAOS_DURATION="${CHAOS_DURATION:-60}"
ACCEPTABLE_RESPONSE_TIME_MS="${ACCEPTABLE_RESPONSE_TIME_MS:-2000}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-}"
PROBE_COUNT="${PROBE_COUNT:-10}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-90}"
OBSERVATION_PERIOD="${OBSERVATION_PERIOD:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
TARGET_INTERFACE="${TARGET_INTERFACE:-eth0}"
PACKET_LOSS_PERCENT="${PACKET_LOSS_PERCENT:-0}"

# Parse config (overrides defaults if values are present)
parse_config

# Re-apply defaults for any empty values after config parsing
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-sample-app}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-chaos-testing}"
LATENCY_MS="${LATENCY_MS:-200}"
JITTER_MS="${JITTER_MS:-50}"
CHAOS_DURATION="${CHAOS_DURATION:-60}"
ACCEPTABLE_RESPONSE_TIME_MS="${ACCEPTABLE_RESPONSE_TIME_MS:-2000}"
PROBE_COUNT="${PROBE_COUNT:-10}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-90}"
OBSERVATION_PERIOD="${OBSERVATION_PERIOD:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
TARGET_INTERFACE="${TARGET_INTERFACE:-eth0}"
PACKET_LOSS_PERCENT="${PACKET_LOSS_PERCENT:-0}"

# Set experiment metadata used by the runner framework
EXPERIMENT_NAME="network-chaos"
EXPERIMENT_DIR="${SCRIPT_DIR}"

# Track targeted pods and baseline response times (for reporting)
TARGETED_PODS=()
BASELINE_RESPONSE_MS=0
PROBE_RESULTS=()

# ---------------------------------------------------------------------------
# Utility — measure HTTP response time in milliseconds
# ---------------------------------------------------------------------------
measure_response_time() {
    local url="$1"
    local timeout_s="${2:-10}"

    # Use curl to measure total request time in milliseconds
    local response_time_ms
    response_time_ms=$(curl -s -o /dev/null -w '%{time_total}' \
        --max-time "${timeout_s}" "${url}" 2>/dev/null \
        | awk '{printf "%.0f", $1 * 1000}')

    echo "${response_time_ms}"
}

# ---------------------------------------------------------------------------
# Utility — inject tc netem rules into a pod via kubectl exec
# ---------------------------------------------------------------------------
inject_tc_rules() {
    local pod="$1"
    local namespace="$2"
    local latency="$3"
    local jitter="$4"
    local loss="$5"
    local interface="$6"

    log_info "Injecting tc rules into pod '${pod}': ${latency}ms delay, ${jitter}ms jitter, ${loss}% loss"

    # Build the tc qdisc command
    local tc_cmd="tc qdisc add dev ${interface} root netem delay ${latency}ms ${jitter}ms"

    # Add packet loss if configured
    if [[ "${loss}" -gt 0 ]]; then
        tc_cmd="${tc_cmd} loss ${loss}%"
    fi

    # Execute tc command inside the pod
    # We use the tc-injector DaemonSet which runs with NET_ADMIN capability
    # and shares the pod's network namespace
    if \! kubectl exec "${pod}" -n "${namespace}" -c tc-injector -- \
        sh -c "${tc_cmd}" 2>/dev/null; then
        # Fallback: try to exec directly into the main container if it has tc
        if \! kubectl exec "${pod}" -n "${namespace}" -- \
            sh -c "${tc_cmd}" 2>/dev/null; then
            log_error "Failed to inject tc rules into pod '${pod}'"
            return 1
        fi
    fi

    log_success "tc rules applied to pod '${pod}'"
}

# ---------------------------------------------------------------------------
# Utility — remove tc netem rules from a pod
# ---------------------------------------------------------------------------
remove_tc_rules() {
    local pod="$1"
    local namespace="$2"
    local interface="$3"

    log_info "Removing tc rules from pod '${pod}'..."

    local tc_cmd="tc qdisc del dev ${interface} root 2>/dev/null || true"

    # Try tc-injector sidecar first, then main container
    kubectl exec "${pod}" -n "${namespace}" -c tc-injector -- \
        sh -c "${tc_cmd}" 2>/dev/null || \
    kubectl exec "${pod}" -n "${namespace}" -- \
        sh -c "${tc_cmd}" 2>/dev/null || true

    log_success "tc rules removed from pod '${pod}'"
}

# ---------------------------------------------------------------------------
# Experiment-specific pre-checks
# ---------------------------------------------------------------------------
experiment_prechecks() {
    local available_pods
    available_pods=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)

    if [[ "${available_pods}" -lt 1 ]]; then
        log_error "No running pods found for deployment '${TARGET_DEPLOYMENT}'"
        return 1
    fi

    log_success "Deployment has ${available_pods} running pod(s)"

    # Verify curl is available for response time measurement
    if \! command -v curl &>/dev/null; then
        log_error "curl is required for response time measurement"
        return 1
    fi

    # Verify health endpoint is set
    if [[ -z "${HEALTH_ENDPOINT}" ]]; then
        log_warn "No health_endpoint configured — response time checks will be skipped"
    fi

    log_info "Network chaos parameters: ${LATENCY_MS}ms delay ± ${JITTER_MS}ms jitter, ${PACKET_LOSS_PERCENT}% loss"
    log_info "Acceptable response time threshold: ${ACCEPTABLE_RESPONSE_TIME_MS}ms"
    log_info "Chaos duration: ${CHAOS_DURATION}s"
}

# ---------------------------------------------------------------------------
# Capture baseline response time before injection
# ---------------------------------------------------------------------------
capture_baseline() {
    if [[ -z "${HEALTH_ENDPOINT}" ]]; then
        log_info "No health endpoint configured, skipping baseline capture"
        BASELINE_RESPONSE_MS=0
        return 0
    fi

    log_info "Capturing baseline response time from ${HEALTH_ENDPOINT}..."

    local total_ms=0
    local samples=3

    for i in $(seq 1 "${samples}"); do
        local ms
        ms=$(measure_response_time "${HEALTH_ENDPOINT}")
        total_ms=$((total_ms + ms))
        log_info "  Baseline probe ${i}/${samples}: ${ms}ms"
        sleep 1
    done

    BASELINE_RESPONSE_MS=$((total_ms / samples))
    log_success "Baseline response time: ${BASELINE_RESPONSE_MS}ms (avg of ${samples} probes)"
}

# ---------------------------------------------------------------------------
# Chaos injection — add tc latency rules to all target pods
# ---------------------------------------------------------------------------
experiment_inject() {
    # Capture baseline before injection
    capture_baseline

    log_info "Injecting network latency into deployment '${TARGET_DEPLOYMENT}'..."

    # Get all running pod names for the target deployment
    local all_pods
    all_pods=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    if [[ -z "${all_pods}" ]]; then
        log_error "No running pods found for injection"
        return 1
    fi

    # Inject tc rules into each pod
    for pod in ${all_pods}; do
        inject_tc_rules "${pod}" "${TARGET_NAMESPACE}" \
            "${LATENCY_MS}" "${JITTER_MS}" \
            "${PACKET_LOSS_PERCENT}" "${TARGET_INTERFACE}"
        TARGETED_PODS+=("${pod}")
    done

    log_success "Latency injection active on ${#TARGETED_PODS[@]} pod(s)"

    # Wait for the observation period
    log_info "Waiting ${OBSERVATION_PERIOD}s observation period..."
    sleep "${OBSERVATION_PERIOD}"

    # Probe the endpoint during the chaos window
    if [[ -n "${HEALTH_ENDPOINT}" && "${PROBE_COUNT}" -gt 0 ]]; then
        local probe_interval=$(( CHAOS_DURATION / PROBE_COUNT ))
        [[ "${probe_interval}" -lt 1 ]] && probe_interval=1

        log_info "Probing endpoint ${PROBE_COUNT} times over ${CHAOS_DURATION}s..."

        for i in $(seq 1 "${PROBE_COUNT}"); do
            local ms
            ms=$(measure_response_time "${HEALTH_ENDPOINT}" 15)
            PROBE_RESULTS+=("${ms}")
            log_info "  Probe ${i}/${PROBE_COUNT}: ${ms}ms"
            sleep "${probe_interval}"
        done
    fi

    log_info "Chaos injection phase complete."
}

# ---------------------------------------------------------------------------
# Experiment-specific validation — check response times were acceptable
# ---------------------------------------------------------------------------
experiment_validate() {
    local failures=0

    if [[ ${#PROBE_RESULTS[@]} -gt 0 ]]; then
        # Calculate p50 and p95 response times from probe results
        local sorted_results
        sorted_results=$(printf '%s\n' "${PROBE_RESULTS[@]}" | sort -n)

        local count=${#PROBE_RESULTS[@]}
        local p50_index=$(( count / 2 ))
        local p95_index=$(( (count * 95) / 100 ))

        local p50
        p50=$(echo "${sorted_results}" | sed -n "$((p50_index + 1))p")
        local p95
        p95=$(echo "${sorted_results}" | sed -n "$((p95_index + 1))p")

        local max_ms
        max_ms=$(printf '%s\n' "${PROBE_RESULTS[@]}" | sort -rn | head -1)
        local min_ms
        min_ms=$(printf '%s\n' "${PROBE_RESULTS[@]}" | sort -n | head -1)

        log_info "Response time summary:"
        log_info "  Baseline: ${BASELINE_RESPONSE_MS}ms"
        log_info "  Under chaos — min: ${min_ms}ms, p50: ${p50}ms, p95: ${p95}ms, max: ${max_ms}ms"

        # Validate p95 is within acceptable threshold
        if [[ "${p95}" -gt "${ACCEPTABLE_RESPONSE_TIME_MS}" ]]; then
            log_error "p95 response time (${p95}ms) exceeds threshold (${ACCEPTABLE_RESPONSE_TIME_MS}ms)"
            ((failures++)) || true
        else
            log_success "p95 response time (${p95}ms) within threshold (${ACCEPTABLE_RESPONSE_TIME_MS}ms)"
        fi

        # Check that at least 80% of probes succeeded (didn't timeout)
        local timeout_count=0
        for ms in "${PROBE_RESULTS[@]}"; do
            if [[ "${ms}" -ge 10000 ]]; then
                ((timeout_count++)) || true
            fi
        done

        local success_rate=$(( ((count - timeout_count) * 100) / count ))
        if [[ "${success_rate}" -lt 80 ]]; then
            log_error "Probe success rate (${success_rate}%) below 80% threshold"
            ((failures++)) || true
        else
            log_success "Probe success rate: ${success_rate}% (${timeout_count} timeouts out of ${count})"
        fi
    else
        log_warn "No probe results to validate (health endpoint may not be configured)"
    fi

    # Verify all pods are still running (latency injection shouldn't crash pods)
    local running_count
    running_count=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)

    local expected_count=${#TARGETED_PODS[@]}
    if [[ "${running_count}" -lt "${expected_count}" ]]; then
        log_error "Pod count dropped during chaos: expected ${expected_count}, got ${running_count}"
        ((failures++)) || true
    else
        log_success "All ${running_count} pods still running after chaos injection"
    fi

    if [[ ${failures} -gt 0 ]]; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Rollback — remove tc rules from all targeted pods
# ---------------------------------------------------------------------------
experiment_rollback() {
    log_info "Rolling back network chaos — removing tc rules from ${#TARGETED_PODS[@]} pod(s)..."

    for pod in "${TARGETED_PODS[@]}"; do
        remove_tc_rules "${pod}" "${TARGET_NAMESPACE}" "${TARGET_INTERFACE}"
    done

    log_success "All tc rules removed"

    # Verify response time recovers to near baseline
    if [[ -n "${HEALTH_ENDPOINT}" && "${BASELINE_RESPONSE_MS}" -gt 0 ]]; then
        log_info "Waiting for response time recovery (timeout: ${RECOVERY_TIMEOUT}s)..."

        local elapsed=0
        local recovered=false
        # Accept response time within 2x baseline as "recovered"
        local recovery_threshold=$(( BASELINE_RESPONSE_MS * 2 ))
        [[ "${recovery_threshold}" -lt 500 ]] && recovery_threshold=500

        while [[ ${elapsed} -lt ${RECOVERY_TIMEOUT} ]]; do
            local current_ms
            current_ms=$(measure_response_time "${HEALTH_ENDPOINT}")

            if [[ "${current_ms}" -le "${recovery_threshold}" ]]; then
                log_success "Response time recovered: ${current_ms}ms (threshold: ${recovery_threshold}ms)"
                recovered=true
                break
            fi

            log_info "  Recovery probe: ${current_ms}ms (waiting for ≤${recovery_threshold}ms)..."
            sleep "${POLL_INTERVAL}"
            elapsed=$((elapsed + POLL_INTERVAL))
        done

        if [[ "${recovered}" \!= "true" ]]; then
            log_warn "Response time did not recover within ${RECOVERY_TIMEOUT}s"
        fi
    fi

    # Wait for deployment to stabilize
    if \! wait_for_pods_ready "${TARGET_DEPLOYMENT}" "${TARGET_NAMESPACE}" 60; then
        log_warn "Deployment may not be fully stable after rollback"
    fi
}

# ---------------------------------------------------------------------------
# Run the experiment
# ---------------------------------------------------------------------------
run_experiment

#!/usr/bin/env bash
# ==============================================================================
# Chaos Engineering Toolkit — Steady-State Helpers
# ==============================================================================
# Functions to capture and validate steady-state metrics:
#   - Pod count for a given deployment
#   - Endpoint health (HTTP status)
#   - Response time baseline
#
# These functions are sourced by experiment_runner.sh and can also be used
# independently in custom experiment scripts.
# ==============================================================================

# ---------------------------------------------------------------------------
# Baseline storage (global variables set during capture, read during validate)
# ---------------------------------------------------------------------------
BASELINE_POD_COUNT=""
BASELINE_HEALTH_STATUS=""
BASELINE_RESPONSE_TIME=""

# ---------------------------------------------------------------------------
# Pod count — capture and validate the number of ready pods
# ---------------------------------------------------------------------------
capture_pod_count() {
    local namespace="${1:-default}"
    local deployment="${2:-}"

    if [[ -z "${deployment}" ]]; then
        log_warn "No target deployment specified; skipping pod count capture"
        return 0
    fi

    BASELINE_POD_COUNT=$(kubectl get deployment "${deployment}" \
        -n "${namespace}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    # Handle empty response (no ready replicas)
    BASELINE_POD_COUNT="${BASELINE_POD_COUNT:-0}"

    log_info "Baseline pod count for ${deployment}: ${BASELINE_POD_COUNT}"
}

validate_pod_count() {
    local namespace="${1:-default}"
    local deployment="${2:-}"

    if [[ -z "${deployment}" || -z "${BASELINE_POD_COUNT}" ]]; then
        return 0
    fi

    local current_count
    current_count=$(kubectl get deployment "${deployment}" \
        -n "${namespace}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    current_count="${current_count:-0}"

    if [[ "${current_count}" -ge "${BASELINE_POD_COUNT}" ]]; then
        log_success "Pod count recovered: ${current_count}/${BASELINE_POD_COUNT}"
        return 0
    else
        log_warn "Pod count not recovered: ${current_count}/${BASELINE_POD_COUNT}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Endpoint health — capture and validate HTTP health check
# ---------------------------------------------------------------------------
capture_endpoint_health() {
    local endpoint="${1:-}"

    if [[ -z "${endpoint}" ]]; then
        log_info "No health endpoint configured; skipping health capture"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 \
        "${endpoint}" 2>/dev/null || echo "000")

    BASELINE_HEALTH_STATUS="${http_code}"
    log_info "Baseline health status for ${endpoint}: HTTP ${http_code}"
}

validate_endpoint_health() {
    local endpoint="${1:-}"

    if [[ -z "${endpoint}" || -z "${BASELINE_HEALTH_STATUS}" ]]; then
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 \
        "${endpoint}" 2>/dev/null || echo "000")

    if [[ "${http_code}" =~ ^2[0-9]{2}$ ]]; then
        log_success "Endpoint healthy: HTTP ${http_code}"
        return 0
    else
        log_warn "Endpoint unhealthy: HTTP ${http_code} (baseline: ${BASELINE_HEALTH_STATUS})"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Response time — capture and validate request latency
# ---------------------------------------------------------------------------
capture_response_time() {
    local endpoint="${1:-}"

    if [[ -z "${endpoint}" ]]; then
        log_info "No health endpoint configured; skipping response time capture"
        return 0
    fi

    local total_time
    total_time=$(curl -s -o /dev/null -w '%{time_total}' \
        --connect-timeout 5 --max-time 10 \
        "${endpoint}" 2>/dev/null || echo "0")

    # Convert to milliseconds
    BASELINE_RESPONSE_TIME=$(echo "${total_time} * 1000" | bc 2>/dev/null || echo "0")
    log_info "Baseline response time for ${endpoint}: ${BASELINE_RESPONSE_TIME}ms"
}

validate_response_time() {
    local endpoint="${1:-}"
    local threshold_multiplier="${2:-3}"  # Allow up to 3x baseline by default

    if [[ -z "${endpoint}" || -z "${BASELINE_RESPONSE_TIME}" ]]; then
        return 0
    fi

    local total_time
    total_time=$(curl -s -o /dev/null -w '%{time_total}' \
        --connect-timeout 5 --max-time 10 \
        "${endpoint}" 2>/dev/null || echo "0")

    local current_ms
    current_ms=$(echo "${total_time} * 1000" | bc 2>/dev/null || echo "0")

    local threshold
    threshold=$(echo "${BASELINE_RESPONSE_TIME} * ${threshold_multiplier}" | bc 2>/dev/null || echo "999999")

    if (( $(echo "${current_ms} <= ${threshold}" | bc -l 2>/dev/null || echo "0") )); then
        log_success "Response time within threshold: ${current_ms}ms (limit: ${threshold}ms)"
        return 0
    else
        log_warn "Response time exceeded: ${current_ms}ms (limit: ${threshold}ms)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Utility — wait for all pods in a deployment to be ready
# ---------------------------------------------------------------------------
wait_for_pods_ready() {
    local deployment="${1}"
    local namespace="${2:-default}"
    local timeout="${3:-120}"

    log_info "Waiting for deployment '${deployment}' to be ready (timeout: ${timeout}s)..."

    if kubectl rollout status deployment/"${deployment}" \
        -n "${namespace}" \
        --timeout="${timeout}s" &>/dev/null; then
        log_success "Deployment '${deployment}' is ready"
        return 0
    else
        log_error "Deployment '${deployment}' did not become ready within ${timeout}s"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Utility — get a list of pod names for a deployment
# ---------------------------------------------------------------------------
get_deployment_pods() {
    local deployment="${1}"
    local namespace="${2:-default}"

    kubectl get pods -n "${namespace}" \
        -l "app=${deployment}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Utility — check if a node is schedulable
# ---------------------------------------------------------------------------
is_node_schedulable() {
    local node="${1}"

    local unschedulable
    unschedulable=$(kubectl get node "${node}" \
        -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "false")

    [[ "${unschedulable}" != "true" ]]
}

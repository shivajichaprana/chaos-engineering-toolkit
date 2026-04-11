#\!/usr/bin/env bash
# ==============================================================================
# Chaos Experiment: Node Drain
# ==============================================================================
# Hypothesis:
#   When a worker node is cordoned and drained, Kubernetes will respect
#   PodDisruptionBudgets (PDBs), gracefully evict pods, and reschedule them
#   onto remaining healthy nodes. The service will remain available throughout
#   the drain operation — PDBs guarantee that a minimum number of pods stay
#   running at all times. After uncordoning, pods will rebalance naturally.
#
# Procedure:
#   1. Validate cluster connectivity and target node existence
#   2. Capture steady-state: node count, pod distribution, endpoint health
#   3. Select a worker node based on the configured strategy
#   4. Cordon the node (mark as unschedulable)
#   5. Drain the node (evict pods respecting PDBs and grace periods)
#   6. Validate: pods rescheduled, PDBs respected, service available
#   7. Rollback: uncordon the node and wait for cluster stabilization
#   8. Generate a Markdown report with pass/fail status
#
# Usage:
#   ./experiments/node-drain/experiment.sh
#   ./experiments/node-drain/experiment.sh --config experiments/node-drain/config.yaml
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths relative to the repository root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source the experiment runner framework
if [[ -f "${REPO_ROOT}/lib/runner.sh" ]]; then
    # shellcheck source=../../lib/runner.sh
    source "${REPO_ROOT}/lib/runner.sh"
fi

# ---------------------------------------------------------------------------
# Default configuration (overridden by config.yaml)
# ---------------------------------------------------------------------------
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-sample-app}"
NAMESPACE="${NAMESPACE:-chaos-testing}"
NODE_SELECTION_STRATEGY="${NODE_SELECTION_STRATEGY:-random}"
SPECIFIC_NODE="${SPECIFIC_NODE:-}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"
GRACE_PERIOD="${GRACE_PERIOD:-30}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-http://localhost:30080/healthz}"
OBSERVATION_PERIOD="${OBSERVATION_PERIOD:-15}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
DELETE_LOCAL_DATA="${DELETE_LOCAL_DATA:-true}"
IGNORE_DAEMONSETS="${IGNORE_DAEMONSETS:-true}"

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $(date '+%H:%M:%S') $*"; }

# ---------------------------------------------------------------------------
# State tracking for cleanup
# ---------------------------------------------------------------------------
CORDONED_NODE=""
REPORT_FILE=""
EXPERIMENT_PASSED=false

# ---------------------------------------------------------------------------
# Cleanup trap — always uncordon on exit
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ -n "${CORDONED_NODE}" ]]; then
        log_warn "Cleanup: uncordoning node ${CORDONED_NODE}"
        kubectl uncordon "${CORDONED_NODE}" 2>/dev/null || true
    fi
    if [[ "${exit_code}" -ne 0 ]] && [[ "${EXPERIMENT_PASSED}" \!= "true" ]]; then
        log_error "Experiment exited with code ${exit_code}"
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run the node drain chaos experiment. Cordons and drains a worker node,
validates PDB compliance and pod rescheduling, then uncordons.

Options:
  --config FILE        Path to config.yaml (default: experiments/node-drain/config.yaml)
  --namespace NS       Kubernetes namespace (default: chaos-testing)
  --deployment NAME    Target deployment name (default: sample-app)
  --strategy STRATEGY  Node selection: random, specific, most-loaded (default: random)
  --node NODE          Specific node name (required when strategy=specific)
  --dry-run            Print what would happen without executing
  -h, --help           Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --strategy most-loaded --namespace production
  $(basename "$0") --strategy specific --node kind-worker2
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse configuration from YAML (lightweight — no yq dependency)
# ---------------------------------------------------------------------------
parse_config() {
    local config_file="$1"
    [[ \! -f "${config_file}" ]] && return 0

    log_info "Loading configuration from ${config_file}"

    while IFS=': ' read -r key value; do
        # Skip comments and empty lines
        [[ "${key}" =~ ^#.*$ ]] && continue
        [[ -z "${key}" ]] && continue

        # Strip leading/trailing whitespace and quotes from value
        value="$(echo "${value}" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        case "${key}" in
            target_deployment)       TARGET_DEPLOYMENT="${value}" ;;
            namespace)               NAMESPACE="${value}" ;;
            node_selection_strategy) NODE_SELECTION_STRATEGY="${value}" ;;
            specific_node)           SPECIFIC_NODE="${value}" ;;
            drain_timeout)           DRAIN_TIMEOUT="${value}" ;;
            grace_period)            GRACE_PERIOD="${value}" ;;
            recovery_timeout)        RECOVERY_TIMEOUT="${value}" ;;
            health_endpoint)         HEALTH_ENDPOINT="${value}" ;;
            observation_period)      OBSERVATION_PERIOD="${value}" ;;
            poll_interval)           POLL_INTERVAL="${value}" ;;
            delete_local_data)       DELETE_LOCAL_DATA="${value}" ;;
            ignore_daemonsets)       IGNORE_DAEMONSETS="${value}" ;;
        esac
    done < "${config_file}"
}

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
DRY_RUN=false
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)      CONFIG_FILE="$2"; shift 2 ;;
        --namespace)   NAMESPACE="$2"; shift 2 ;;
        --deployment)  TARGET_DEPLOYMENT="$2"; shift 2 ;;
        --strategy)    NODE_SELECTION_STRATEGY="$2"; shift 2 ;;
        --node)        SPECIFIC_NODE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        *)             log_error "Unknown option: $1"; usage ;;
    esac
done

# Load config file (CLI args take precedence — already set above)
parse_config "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    log_step "Running pre-flight checks"

    # Verify kubectl is available
    if \! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        exit 1
    fi

    # Verify cluster connectivity
    if \! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_ok "Cluster connectivity verified"

    # Verify namespace exists
    if \! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_error "Namespace '${NAMESPACE}' does not exist"
        exit 1
    fi
    log_ok "Namespace '${NAMESPACE}' exists"

    # Verify target deployment exists
    if \! kubectl get deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" &>/dev/null; then
        log_error "Deployment '${TARGET_DEPLOYMENT}' not found in namespace '${NAMESPACE}'"
        exit 1
    fi
    log_ok "Deployment '${TARGET_DEPLOYMENT}' found"

    # Verify at least 2 worker nodes are available (need somewhere to reschedule)
    local worker_count
    worker_count=$(kubectl get nodes --selector='\!node-role.kubernetes.io/control-plane' \
        --no-headers 2>/dev/null | wc -l)
    if [[ "${worker_count}" -lt 2 ]]; then
        log_error "Need at least 2 worker nodes for node drain experiment (found: ${worker_count})"
        exit 1
    fi
    log_ok "Worker node count: ${worker_count} (minimum 2 required)"

    # Verify strategy is valid
    case "${NODE_SELECTION_STRATEGY}" in
        random|specific|most-loaded) ;;
        *)
            log_error "Invalid node selection strategy: '${NODE_SELECTION_STRATEGY}'"
            log_error "Valid options: random, specific, most-loaded"
            exit 1
            ;;
    esac

    # If specific strategy, verify node name is provided
    if [[ "${NODE_SELECTION_STRATEGY}" == "specific" ]] && [[ -z "${SPECIFIC_NODE}" ]]; then
        log_error "Strategy 'specific' requires --node or specific_node in config"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Node selection
# ---------------------------------------------------------------------------
select_target_node() {
    log_step "Selecting target node (strategy: ${NODE_SELECTION_STRATEGY})"

    local selected_node=""

    case "${NODE_SELECTION_STRATEGY}" in
        random)
            # Select a random worker node (exclude control-plane)
            selected_node=$(kubectl get nodes \
                --selector='\!node-role.kubernetes.io/control-plane' \
                --no-headers -o custom-columns=':metadata.name' \
                | shuf -n 1)
            ;;
        specific)
            # Use the configured specific node
            if \! kubectl get node "${SPECIFIC_NODE}" &>/dev/null; then
                log_error "Specified node '${SPECIFIC_NODE}' not found"
                exit 1
            fi
            selected_node="${SPECIFIC_NODE}"
            ;;
        most-loaded)
            # Select the worker node running the most pods
            selected_node=$(kubectl get pods --all-namespaces \
                -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
                | grep -v "^$" \
                | sort | uniq -c | sort -rn \
                | while read -r count node; do
                    # Skip control-plane nodes
                    local roles
                    roles=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)
                    if [[ -z "${roles}" ]]; then
                        echo "${node}"
                        break
                    fi
                done)
            ;;
    esac

    if [[ -z "${selected_node}" ]]; then
        log_error "Failed to select a target node"
        exit 1
    fi

    log_ok "Selected node: ${selected_node}"
    echo "${selected_node}"
}

# ---------------------------------------------------------------------------
# Steady-state capture
# ---------------------------------------------------------------------------
capture_steady_state() {
    log_step "Capturing steady-state metrics"

    # Node status
    local node_count
    node_count=$(kubectl get nodes --no-headers | grep -c " Ready" || true)
    log_info "Ready nodes: ${node_count}"

    # Pod count for target deployment
    local pod_count
    pod_count=$(kubectl get pods -n "${NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" --field-selector=status.phase=Running \
        --no-headers 2>/dev/null | wc -l)
    log_info "Running pods for '${TARGET_DEPLOYMENT}': ${pod_count}"

    # Pod distribution across nodes
    log_info "Pod distribution:"
    kubectl get pods -n "${NAMESPACE}" -l "app=${TARGET_DEPLOYMENT}" \
        -o wide --no-headers 2>/dev/null | awk '{print "  " $7 ": " $1 " (" $3 ")"}'

    # PDB status
    log_info "PodDisruptionBudgets in namespace '${NAMESPACE}':"
    kubectl get pdb -n "${NAMESPACE}" --no-headers 2>/dev/null | while read -r line; do
        log_info "  ${line}"
    done

    # Health endpoint check
    if [[ -n "${HEALTH_ENDPOINT}" ]]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 "${HEALTH_ENDPOINT}" 2>/dev/null || echo "000")
        if [[ "${http_code}" == "200" ]]; then
            log_ok "Health endpoint returned HTTP ${http_code}"
        else
            log_warn "Health endpoint returned HTTP ${http_code} (expected 200)"
        fi
    fi

    # Export steady-state values for later comparison
    STEADY_STATE_POD_COUNT="${pod_count}"
    STEADY_STATE_NODE_COUNT="${node_count}"
}

# ---------------------------------------------------------------------------
# Cordon and drain
# ---------------------------------------------------------------------------
cordon_and_drain() {
    local target_node="$1"

    # --- Cordon ---
    log_step "Cordoning node '${target_node}' (marking unschedulable)"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warn "[DRY RUN] Would cordon node: ${target_node}"
        return 0
    fi

    kubectl cordon "${target_node}"
    CORDONED_NODE="${target_node}"
    log_ok "Node '${target_node}' cordoned"

    # Verify cordon took effect
    local sched_status
    sched_status=$(kubectl get node "${target_node}" -o jsonpath='{.spec.unschedulable}')
    if [[ "${sched_status}" \!= "true" ]]; then
        log_error "Node cordon did not take effect"
        exit 1
    fi

    # --- Drain ---
    log_step "Draining node '${target_node}' (timeout: ${DRAIN_TIMEOUT}s, grace: ${GRACE_PERIOD}s)"

    local drain_cmd="kubectl drain ${target_node} --timeout=${DRAIN_TIMEOUT}s --grace-period=${GRACE_PERIOD}"

    if [[ "${IGNORE_DAEMONSETS}" == "true" ]]; then
        drain_cmd="${drain_cmd} --ignore-daemonsets"
    fi
    if [[ "${DELETE_LOCAL_DATA}" == "true" ]]; then
        drain_cmd="${drain_cmd} --delete-emptydir-data"
    fi

    log_info "Executing: ${drain_cmd}"
    if eval "${drain_cmd}"; then
        log_ok "Node '${target_node}' drained successfully"
    else
        log_error "Node drain failed or timed out"
        log_warn "This may indicate PDB constraints prevented full eviction"
        # Don't exit — we still want to validate and report
    fi
}

# ---------------------------------------------------------------------------
# Validation: PDB compliance + pod rescheduling + service availability
# ---------------------------------------------------------------------------
validate_experiment() {
    local target_node="$1"
    local start_time
    start_time=$(date +%s)

    log_step "Waiting ${OBSERVATION_PERIOD}s observation period before validation"
    sleep "${OBSERVATION_PERIOD}"

    log_step "Validating experiment results"

    local pdb_respected=true
    local pods_rescheduled=false
    local service_available=false
    local elapsed=0

    # --- Check PDB compliance ---
    log_info "Checking PDB compliance..."
    local pdb_list
    pdb_list=$(kubectl get pdb -n "${NAMESPACE}" -o json 2>/dev/null)

    if [[ -n "${pdb_list}" ]] && echo "${pdb_list}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pdb in data.get('items', []):
    status = pdb.get('status', {})
    current = status.get('currentHealthy', 0)
    desired = status.get('desiredHealthy', 0)
    name = pdb['metadata']['name']
    if current < desired:
        print(f'VIOLATION: PDB {name} — currentHealthy={current} < desiredHealthy={desired}')
        sys.exit(1)
    else:
        print(f'OK: PDB {name} — currentHealthy={current} >= desiredHealthy={desired}')
" 2>/dev/null; then
        log_ok "All PDBs respected during drain"
    else
        log_error "PDB violation detected"
        pdb_respected=false
    fi

    # --- Poll for pod rescheduling ---
    log_info "Waiting for pods to reschedule (timeout: ${RECOVERY_TIMEOUT}s)..."
    while [[ "${elapsed}" -lt "${RECOVERY_TIMEOUT}" ]]; do
        local current_running
        current_running=$(kubectl get pods -n "${NAMESPACE}" \
            -l "app=${TARGET_DEPLOYMENT}" --field-selector=status.phase=Running \
            --no-headers 2>/dev/null | wc -l)

        # Check no pods are on the drained node
        local pods_on_drained
        pods_on_drained=$(kubectl get pods -n "${NAMESPACE}" \
            -l "app=${TARGET_DEPLOYMENT}" \
            -o jsonpath="{.items[?(@.spec.nodeName=='${target_node}')].metadata.name}" \
            2>/dev/null)

        if [[ "${current_running}" -ge "${STEADY_STATE_POD_COUNT}" ]] && [[ -z "${pods_on_drained}" ]]; then
            log_ok "Pods rescheduled: ${current_running}/${STEADY_STATE_POD_COUNT} running, none on drained node"
            pods_rescheduled=true
            break
        fi

        log_info "  Pods: ${current_running}/${STEADY_STATE_POD_COUNT} running, still on drained node: ${pods_on_drained:-none}"
        sleep "${POLL_INTERVAL}"
        elapsed=$(( $(date +%s) - start_time ))
    done

    if [[ "${pods_rescheduled}" \!= "true" ]]; then
        log_error "Pods did not fully reschedule within ${RECOVERY_TIMEOUT}s"
    fi

    # --- Health endpoint check ---
    if [[ -n "${HEALTH_ENDPOINT}" ]]; then
        log_info "Checking service availability..."
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 "${HEALTH_ENDPOINT}" 2>/dev/null || echo "000")
        if [[ "${http_code}" == "200" ]]; then
            log_ok "Service healthy (HTTP ${http_code})"
            service_available=true
        else
            log_warn "Service returned HTTP ${http_code}"
        fi
    else
        # No endpoint configured — skip health check
        service_available=true
    fi

    # --- Final verdict ---
    if [[ "${pdb_respected}" == "true" ]] && [[ "${pods_rescheduled}" == "true" ]] && [[ "${service_available}" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Rollback: uncordon the node
# ---------------------------------------------------------------------------
rollback() {
    local target_node="$1"

    log_step "Rolling back: uncordoning node '${target_node}'"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warn "[DRY RUN] Would uncordon node: ${target_node}"
        return 0
    fi

    kubectl uncordon "${target_node}"
    CORDONED_NODE=""  # Clear so cleanup trap doesn't double-uncordon
    log_ok "Node '${target_node}' uncordoned and schedulable"

    # Wait briefly for cluster to stabilize
    log_info "Waiting 10s for cluster stabilization..."
    sleep 10

    # Show final pod distribution
    log_info "Final pod distribution:"
    kubectl get pods -n "${NAMESPACE}" -l "app=${TARGET_DEPLOYMENT}" \
        -o wide --no-headers 2>/dev/null | awk '{print "  " $7 ": " $1 " (" $3 ")"}'
}

# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------
generate_report() {
    local target_node="$1"
    local result="$2"  # PASS or FAIL
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    REPORT_FILE="${REPO_ROOT}/reports/node-drain-${timestamp//[:.]/-}.md"
    mkdir -p "$(dirname "${REPORT_FILE}")"

    cat > "${REPORT_FILE}" << REPORT
# Node Drain Experiment Report

**Timestamp:** ${timestamp}
**Result:** ${result}

## Configuration

| Parameter | Value |
|-----------|-------|
| Target Deployment | ${TARGET_DEPLOYMENT} |
| Namespace | ${NAMESPACE} |
| Drained Node | ${target_node} |
| Selection Strategy | ${NODE_SELECTION_STRATEGY} |
| Drain Timeout | ${DRAIN_TIMEOUT}s |
| Grace Period | ${GRACE_PERIOD}s |
| Recovery Timeout | ${RECOVERY_TIMEOUT}s |

## Steady State

- **Nodes (Ready):** ${STEADY_STATE_NODE_COUNT}
- **Pods (Running):** ${STEADY_STATE_POD_COUNT}

## Hypothesis

When worker node \`${target_node}\` is cordoned and drained:
1. PodDisruptionBudgets will be respected — minimum available pods maintained
2. Evicted pods will reschedule to remaining healthy nodes
3. Service endpoint will remain available throughout the operation

## Result: ${result}

$(if [[ "${result}" == "PASS" ]]; then
    echo "All validation checks passed. The cluster correctly handled the node drain operation."
else
    echo "One or more validation checks failed. Review the experiment output above for details."
fi)
REPORT

    log_ok "Report saved to ${REPORT_FILE}"
}

# ===========================================================================
# Main experiment flow
# ===========================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  Chaos Experiment: Node Drain"
    echo "  Target: ${TARGET_DEPLOYMENT} in ${NAMESPACE}"
    echo "  Strategy: ${NODE_SELECTION_STRATEGY}"
    echo "============================================================"
    echo ""

    # Phase 1: Pre-flight
    preflight_checks

    # Phase 2: Steady-state capture
    capture_steady_state

    # Phase 3: Select target node
    local target_node
    target_node=$(select_target_node)

    # Phase 4: Inject chaos — cordon + drain
    cordon_and_drain "${target_node}"

    # Phase 5: Validate
    local result="FAIL"
    if validate_experiment "${target_node}"; then
        result="PASS"
        EXPERIMENT_PASSED=true
        log_ok "========================================="
        log_ok "  EXPERIMENT PASSED"
        log_ok "========================================="
    else
        log_error "========================================="
        log_error "  EXPERIMENT FAILED"
        log_error "========================================="
    fi

    # Phase 6: Rollback
    rollback "${target_node}"

    # Phase 7: Report
    generate_report "${target_node}" "${result}"

    if [[ "${result}" == "PASS" ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"

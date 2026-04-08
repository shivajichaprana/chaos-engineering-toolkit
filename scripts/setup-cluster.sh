#!/usr/bin/env bash
# ==============================================================================
# Chaos Engineering Toolkit — Kind Cluster Setup
# ==============================================================================
# Creates a local Kind cluster with 1 control plane + 3 worker nodes,
# deploys the sample application, and optionally installs Prometheus
# for metric collection during experiments.
#
# Usage:
#   ./scripts/setup-cluster.sh [--with-monitoring]
#
# Prerequisites:
#   - kind (https://kind.sigs.k8s.io/)
#   - kubectl
#   - helm (optional, for Prometheus)
#   - docker
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KIND_CONFIG="${PROJECT_ROOT}/kind-config.yaml"
INSTALL_MONITORING=false

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --with-monitoring    Install Prometheus & Grafana for metric collection
  --cluster-name NAME  Override the Kind cluster name (default: chaos-lab)
  --delete             Delete the existing cluster and exit
  -h, --help           Show this help message

Environment variables:
  CLUSTER_NAME         Kind cluster name (default: chaos-lab)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-monitoring)  INSTALL_MONITORING=true; shift ;;
        --cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
        --delete)           kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null; exit 0 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()
    for cmd in kind kubectl docker; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done

    if [[ "${INSTALL_MONITORING}" == "true" ]] && ! command -v helm &>/dev/null; then
        missing+=("helm")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them before running this script."
        exit 1
    fi

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi

    log_success "All prerequisites met"
}

# ---------------------------------------------------------------------------
# Create Kind cluster
# ---------------------------------------------------------------------------
create_cluster() {
    # Check if cluster already exists
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists"
        read -r -p "Delete and recreate? [y/N] " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            log_info "Deleting existing cluster..."
            kind delete cluster --name "${CLUSTER_NAME}"
        else
            log_info "Using existing cluster"
            kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null || {
                log_error "Cannot connect to existing cluster. Try deleting it first."
                exit 1
            }
            return 0
        fi
    fi

    log_info "Creating Kind cluster '${CLUSTER_NAME}'..."
    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config "${KIND_CONFIG}" \
        --wait 60s

    log_success "Cluster '${CLUSTER_NAME}' created"
}

# ---------------------------------------------------------------------------
# Deploy sample application
# ---------------------------------------------------------------------------
deploy_sample_app() {
    log_info "Deploying sample application..."

    # Create the chaos-sandbox namespace
    kubectl create namespace chaos-sandbox --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespace 'chaos-sandbox' ready"

    # Apply sample app manifests
    kubectl apply -f "${PROJECT_ROOT}/manifests/sample-app/"
    log_info "Waiting for sample-app deployment to be ready..."
    kubectl rollout status deployment/sample-app \
        -n chaos-sandbox \
        --timeout=120s

    log_success "Sample application deployed (3 replicas)"

    # Show pod status
    echo ""
    kubectl get pods -n chaos-sandbox -o wide
    echo ""
}

# ---------------------------------------------------------------------------
# Install monitoring stack (optional)
# ---------------------------------------------------------------------------
install_monitoring() {
    if [[ "${INSTALL_MONITORING}" != "true" ]]; then
        log_info "Skipping monitoring installation (use --with-monitoring to enable)"
        return 0
    fi

    log_info "Installing Prometheus monitoring stack..."

    # Add Prometheus helm repo
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Install kube-prometheus-stack (Prometheus + Grafana)
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set grafana.service.type=NodePort \
        --set grafana.service.nodePort=31000 \
        --set grafana.adminPassword=chaos-admin \
        --wait \
        --timeout 300s

    log_success "Monitoring stack installed"
    log_info "Grafana available at http://localhost:31000 (admin / chaos-admin)"
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================================"
    echo "  Chaos Lab Setup Complete"
    echo "============================================================"
    echo ""
    echo "  Cluster:       ${CLUSTER_NAME}"
    echo "  Context:       kind-${CLUSTER_NAME}"
    echo "  Namespace:     chaos-sandbox"
    echo "  Sample App:    3 replicas (nginx)"
    echo "  Health Check:  http://localhost:30080/health"
    echo ""
    if [[ "${INSTALL_MONITORING}" == "true" ]]; then
        echo "  Grafana:       http://localhost:31000"
        echo "  Grafana Login: admin / chaos-admin"
        echo ""
    fi
    echo "  Run an experiment:"
    echo "    ./experiments/pod-failure/experiment.sh"
    echo ""
    echo "  Delete the cluster:"
    echo "    kind delete cluster --name ${CLUSTER_NAME}"
    echo ""
    echo "============================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "============================================================"
    echo "  Chaos Engineering Toolkit — Cluster Setup"
    echo "============================================================"
    echo ""

    check_prerequisites
    create_cluster
    deploy_sample_app
    install_monitoring
    print_summary
}

main "$@"

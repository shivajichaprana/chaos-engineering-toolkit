# ==============================================================================
# Chaos Engineering Toolkit — Makefile
# ==============================================================================
# Targets for setting up, running, and testing chaos experiments.
#
# Usage:
#   make setup          — Create Kind cluster and deploy sample application
#   make run-all        — Run all experiments in sequence
#   make run-pod-failure — Run the pod failure experiment
#   make run-network-chaos — Run the network chaos experiment
#   make run-node-drain — Run the node drain experiment
#   make report         — Generate a combined report from last run
#   make test           — Run BATS unit tests
#   make lint           — Run shellcheck on all shell scripts
#   make clean          — Tear down Kind cluster and remove reports
# ==============================================================================

.PHONY: setup run-all run-pod-failure run-network-chaos run-node-drain \
        report test lint clean help

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME ?= chaos-toolkit
NAMESPACE    ?= default
PAUSE        ?= 30
REPORTS_DIR  ?= reports

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
BLUE  := \033[0;34m
GREEN := \033[0;32m
NC    := \033[0m

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

## setup: Create Kind cluster and deploy sample application
setup:
	@echo -e "$(BLUE)[setup]$(NC) Creating Kind cluster '$(CLUSTER_NAME)'..."
	@bash scripts/setup-cluster.sh
	@echo -e "$(GREEN)[setup]$(NC) Cluster ready. Deploying sample application..."
	@kubectl apply -f manifests/sample-app/
	@kubectl apply -f manifests/sample-app/pdb.yaml 2>/dev/null || true
	@kubectl rollout status deployment/sample-app -n $(NAMESPACE) --timeout=120s
	@echo -e "$(GREEN)[setup]$(NC) Sample application deployed and ready."

## run-all: Run all chaos experiments in sequence
run-all:
	@echo -e "$(BLUE)[run-all]$(NC) Starting experiment orchestrator..."
	@bash scripts/run-all.sh --pause $(PAUSE) --output $(REPORTS_DIR)

## run-pod-failure: Run the pod failure experiment
run-pod-failure:
	@echo -e "$(BLUE)[run]$(NC) Running pod failure experiment..."
	@bash experiments/pod-failure/experiment.sh

## run-network-chaos: Run the network chaos experiment
run-network-chaos:
	@echo -e "$(BLUE)[run]$(NC) Running network chaos experiment..."
	@bash experiments/network-chaos/experiment.sh

## run-node-drain: Run the node drain experiment
run-node-drain:
	@echo -e "$(BLUE)[run]$(NC) Running node drain experiment..."
	@bash experiments/node-drain/experiment.sh

## report: Generate a combined report (requires previous run data)
report:
	@echo -e "$(BLUE)[report]$(NC) Generating combined report..."
	@mkdir -p $(REPORTS_DIR)
	@bash scripts/run-all.sh --dry-run --output $(REPORTS_DIR)
	@echo -e "$(GREEN)[report]$(NC) Report generated in $(REPORTS_DIR)/"

## test: Run BATS unit tests
test:
	@echo -e "$(BLUE)[test]$(NC) Running BATS tests..."
	@if command -v bats &>/dev/null; then \
		bats tests/; \
	else \
		echo "BATS not installed. Install with: brew install bats-core"; \
		exit 1; \
	fi

## lint: Run shellcheck on all shell scripts
lint:
	@echo -e "$(BLUE)[lint]$(NC) Running shellcheck..."
	@if command -v shellcheck &>/dev/null; then \
		find . -name '*.sh' -not -path './.git/*' -exec shellcheck -x {} +; \
		echo -e "$(GREEN)[lint]$(NC) All scripts passed shellcheck."; \
	else \
		echo "shellcheck not installed. Install with: brew install shellcheck"; \
		exit 1; \
	fi

## clean: Tear down Kind cluster and remove reports
clean:
	@echo -e "$(BLUE)[clean]$(NC) Deleting Kind cluster '$(CLUSTER_NAME)'..."
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@rm -rf $(REPORTS_DIR)
	@echo -e "$(GREEN)[clean]$(NC) Cleanup complete."

## help: Show this help message
help:
	@echo ""
	@echo "Chaos Engineering Toolkit — Available Targets"
	@echo "=============================================="
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
	@echo ""

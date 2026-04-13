# Experiment Authoring Guide

This guide walks you through creating a new chaos experiment using the framework's lifecycle manager.

## Overview

Every experiment in this toolkit follows a structured 6-phase lifecycle managed by `lib/experiment_runner.sh`:

1. **Pre-checks** — Validate cluster connectivity, namespace existence, and target deployment health
2. **Steady-state capture** — Record baseline metrics (pod count, endpoint count, HTTP health)
3. **Chaos injection** — Execute the experiment's chaos action (your custom logic)
4. **Observation** — Wait for a configurable observation period
5. **Validation** — Compare current state against the captured baseline with retry logic
6. **Rollback & Report** — Restore the system to pre-chaos state and generate a Markdown report

You only need to implement two functions: `experiment_inject` (the chaos action) and `experiment_rollback` (the cleanup).

## Step 1: Create the Experiment Directory

```bash
mkdir -p experiments/my-experiment
```

Each experiment needs three files:

```
experiments/my-experiment/
├── experiment.sh     # Main experiment script
├── config.yaml       # Default configuration
└── README.md         # Experiment documentation
```

## Step 2: Write the Experiment Script

Create `experiments/my-experiment/experiment.sh`:

```bash
#\!/usr/bin/env bash
# ---------------------------------------------------------------
# Chaos Experiment: My Experiment
# Description: Brief description of what this experiment does
# ---------------------------------------------------------------
set -euo pipefail

# --- Experiment metadata ---
EXPERIMENT_NAME="my-experiment"
EXPERIMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Default configuration ---
TARGET_NAMESPACE="${TARGET_NAMESPACE:-chaos-sandbox}"
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-sample-app}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
OBSERVATION_PERIOD="${OBSERVATION_PERIOD:-30}"

# --- Source the framework ---
REPO_ROOT="$(cd "${EXPERIMENT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/lib/experiment_runner.sh"

# --- Required: Chaos injection function ---
# This is called during phase 3 of the experiment lifecycle.
# It should perform the destructive action and return 0 on success.
experiment_inject() {
    log "INFO" "Injecting chaos: <describe action>"

    # Example: Delete a random pod
    local target_pod
    target_pod=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "app=${TARGET_DEPLOYMENT}" \
        -o jsonpath='{.items[0].metadata.name}')

    kubectl delete pod -n "${TARGET_NAMESPACE}" "${target_pod}" --wait=false
    log "INFO" "Deleted pod: ${target_pod}"
}

# --- Required: Rollback function ---
# This is called after validation (pass or fail) to restore the system.
# It should be idempotent — safe to call even if injection partially failed.
experiment_rollback() {
    log "INFO" "Rolling back: <describe cleanup>"

    # Example: No manual rollback needed for pod deletion
    # Kubernetes will reschedule automatically
    echo "No manual rollback needed"
}

# --- Run the experiment ---
run_experiment
```

Make it executable:

```bash
chmod +x experiments/my-experiment/experiment.sh
```

## Step 3: Write the Configuration File

Create `experiments/my-experiment/config.yaml`:

```yaml
name: my-experiment
description: Brief description of the experiment
category: <pod|network|node|resource>

target:
  namespace: chaos-sandbox
  deployment: sample-app

parameters:
  recovery_timeout: 120
  poll_interval: 5
  observation_period: 30
  # Add experiment-specific parameters here

steady_state:
  checks:
    - type: pod_count
      expected: 3
    - type: endpoint_health
      path: /healthz
      expected_status: 200

rollback:
  automatic: true
  description: How the system is restored after the experiment
```

## Step 4: Write the README

Create `experiments/my-experiment/README.md`:

```markdown
# My Experiment

## What It Does

Describe the chaos action in plain language.

## What It Validates

- Resilience property 1
- Resilience property 2

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| TARGET_NAMESPACE | Target namespace | chaos-sandbox |
| CUSTOM_PARAM | Your param | default_value |

## Usage

\`\`\`bash
./experiments/my-experiment/experiment.sh
\`\`\`
```

## Step 5: Test Locally

```bash
# Ensure Kind cluster is running
./scripts/setup-cluster.sh

# Run your experiment
./experiments/my-experiment/experiment.sh

# Check the generated report
cat experiments/my-experiment/report-*.md
```

## Step 6: Add Tests

Create a BATS test file at `tests/test_my_experiment.bats`:

```bash
#\!/usr/bin/env bats

setup() {
    export EXPERIMENT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../experiments/my-experiment" && pwd)"
}

@test "experiment script is executable" {
    [ -x "${EXPERIMENT_DIR}/experiment.sh" ]
}

@test "config.yaml exists and is valid" {
    [ -f "${EXPERIMENT_DIR}/config.yaml" ]
}

@test "experiment sources framework library" {
    grep -q "source.*experiment_runner.sh" "${EXPERIMENT_DIR}/experiment.sh"
}

@test "experiment implements inject function" {
    grep -q "experiment_inject()" "${EXPERIMENT_DIR}/experiment.sh"
}

@test "experiment implements rollback function" {
    grep -q "experiment_rollback()" "${EXPERIMENT_DIR}/experiment.sh"
}
```

## Framework API Reference

### Functions Provided by `lib/experiment_runner.sh`

| Function | Description |
|----------|-------------|
| `run_experiment` | Main entry point — orchestrates the full 6-phase lifecycle |
| `log LEVEL MESSAGE` | Structured logging with timestamp and color output |
| `check_prerequisites` | Validates kubectl, cluster connectivity, namespace, and deployment |

### Functions Provided by `lib/steady_state.sh`

| Function | Description |
|----------|-------------|
| `capture_steady_state` | Records baseline pod count, endpoints, and optional HTTP health |
| `validate_steady_state` | Compares current state against baseline with retry loop |

### Functions Provided by `lib/report_generator.sh`

| Function | Description |
|----------|-------------|
| `generate_report` | Creates a Markdown report with before/after comparison |
| `append_to_report SECTION CONTENT` | Adds a custom section to the report |

### Environment Variables

All experiments inherit these variables from the framework:

| Variable | Description | Default |
|----------|-------------|---------|
| `EXPERIMENT_NAME` | Name used in reports and logs | _(required)_ |
| `EXPERIMENT_DIR` | Absolute path to the experiment directory | _(required)_ |
| `TARGET_NAMESPACE` | Kubernetes namespace to target | `chaos-sandbox` |
| `TARGET_DEPLOYMENT` | Deployment name to target | `sample-app` |
| `RECOVERY_TIMEOUT` | Max seconds to wait for recovery | `120` |
| `POLL_INTERVAL` | Seconds between validation retries | `5` |
| `OBSERVATION_PERIOD` | Seconds to wait after chaos injection | `0` |
| `HEALTH_ENDPOINT` | Optional HTTP endpoint for health checks | _(none)_ |

## Tips

- Keep `experiment_inject` focused on a single failure mode. Compound failures are harder to diagnose.
- Make `experiment_rollback` idempotent — it may be called even if injection failed partway through.
- Use `OBSERVATION_PERIOD` to let the system react before validating. Network experiments often need 10–30 seconds.
- Test experiments against the sample app first before pointing at real workloads.
- Set `RECOVERY_TIMEOUT` based on your SLO expectations, not just "whatever works."

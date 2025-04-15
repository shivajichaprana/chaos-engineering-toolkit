#\!/usr/bin/env bash
# ==============================================================================
# Chaos Engineering Toolkit — Experiment Orchestrator
# ==============================================================================
# Runs all chaos experiments in sequence with a configurable pause between each
# experiment. Generates a combined Markdown report at the end.
#
# Usage:
#   ./scripts/run-all.sh [OPTIONS]
#
# Options:
#   -p, --pause SECONDS    Pause between experiments (default: 30)
#   -e, --experiments LIST Comma-separated list of experiments to run
#                          (default: all experiments in experiments/ directory)
#   -o, --output DIR       Output directory for combined report (default: reports/)
#   -d, --dry-run          Show what would be run without executing
#   -h, --help             Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source the report generator library
# shellcheck source=lib/report_generator.sh
source "${PROJECT_ROOT}/lib/report_generator.sh"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PAUSE_SECONDS=30
EXPERIMENTS=()
OUTPUT_DIR="${PROJECT_ROOT}/reports"
DRY_RUN=false

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}Chaos Engineering Toolkit — Experiment Orchestrator${NC}

Usage: $(basename "$0") [OPTIONS]

Options:
  -p, --pause SECONDS    Pause between experiments (default: ${PAUSE_SECONDS})
  -e, --experiments LIST Comma-separated experiment names (default: all)
  -o, --output DIR       Output directory for report (default: reports/)
  -d, --dry-run          Show plan without executing
  -h, --help             Show this help message

Examples:
  $(basename "$0")                              # Run all experiments
  $(basename "$0") -p 60                        # 60s pause between experiments
  $(basename "$0") -e pod-failure,network-chaos  # Run specific experiments
  $(basename "$0") -d                           # Dry-run mode
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--pause)
                PAUSE_SECONDS="${2:?Error: --pause requires a value}"
                shift 2
                ;;
            -e|--experiments)
                IFS=',' read -ra EXPERIMENTS <<< "${2:?Error: --experiments requires a value}"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="${2:?Error: --output requires a value}"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Discover available experiments
# ---------------------------------------------------------------------------
discover_experiments() {
    local experiments_dir="${PROJECT_ROOT}/experiments"

    if [[ ${#EXPERIMENTS[@]} -eq 0 ]]; then
        # Auto-discover from experiments/ directory
        for dir in "${experiments_dir}"/*/; do
            if [[ -f "${dir}/experiment.sh" ]]; then
                local name
                name="$(basename "${dir}")"
                EXPERIMENTS+=("${name}")
            fi
        done
    fi

    if [[ ${#EXPERIMENTS[@]} -eq 0 ]]; then
        echo -e "${RED}Error: No experiments found in ${experiments_dir}${NC}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Validate experiments exist
# ---------------------------------------------------------------------------
validate_experiments() {
    local experiments_dir="${PROJECT_ROOT}/experiments"
    local valid=true

    for experiment in "${EXPERIMENTS[@]}"; do
        if [[ \! -f "${experiments_dir}/${experiment}/experiment.sh" ]]; then
            echo -e "${RED}Error: Experiment '${experiment}' not found at ${experiments_dir}/${experiment}/experiment.sh${NC}" >&2
            valid=false
        fi
    done

    if [[ "${valid}" \!= "true" ]]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Run a single experiment and capture result
# ---------------------------------------------------------------------------
run_single_experiment() {
    local experiment_name="$1"
    local experiment_script="${PROJECT_ROOT}/experiments/${experiment_name}/experiment.sh"
    local start_time end_time duration status

    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Running experiment: ${experiment_name}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    start_time="$(date '+%Y-%m-%d %H:%M:%S')"
    local start_epoch
    start_epoch="$(date '+%s')"

    if bash "${experiment_script}"; then
        status="PASSED"
    else
        status="FAILED"
    fi

    end_time="$(date '+%Y-%m-%d %H:%M:%S')"
    local end_epoch
    end_epoch="$(date '+%s')"
    duration=$(( end_epoch - start_epoch ))

    # Record result for combined report
    record_experiment_result "${experiment_name}" "${status}" "${start_time}" "${end_time}" "${duration}"

    echo -e "\n${BLUE}[INFO]${NC}  Experiment '${experiment_name}' completed with status: ${status} (${duration}s)"
}

# ---------------------------------------------------------------------------
# Main orchestration loop
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    discover_experiments
    validate_experiments

    local total=${#EXPERIMENTS[@]}
    local run_start
    run_start="$(date '+%Y-%m-%d %H:%M:%S')"

    echo -e "\n${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║       Chaos Engineering Toolkit — Orchestrator              ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Experiments to run: ${total}"
    echo -e "${BOLD}║${NC}  Pause between runs: ${PAUSE_SECONDS}s"
    echo -e "${BOLD}║${NC}  Experiments: ${EXPERIMENTS[*]}"
    echo -e "${BOLD}║${NC}  Output directory: ${OUTPUT_DIR}"
    echo -e "${BOLD}║${NC}  Dry run: ${DRY_RUN}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}\n"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${YELLOW}[DRY RUN] Would execute the following experiments:${NC}"
        for i in "${\!EXPERIMENTS[@]}"; do
            echo -e "  $((i + 1)). ${EXPERIMENTS[$i]}"
        done
        echo -e "\n${YELLOW}[DRY RUN] No experiments were executed.${NC}"
        return 0
    fi

    # Initialize the report collector
    init_report_collector

    local passed=0
    local failed=0

    for i in "${\!EXPERIMENTS[@]}"; do
        local experiment="${EXPERIMENTS[$i]}"
        local experiment_num=$((i + 1))

        echo -e "${BLUE}[INFO]${NC}  Running experiment ${experiment_num}/${total}: ${experiment}"

        if run_single_experiment "${experiment}"; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi

        # Pause between experiments (skip after the last one)
        if [[ ${experiment_num} -lt ${total} && ${PAUSE_SECONDS} -gt 0 ]]; then
            echo -e "\n${YELLOW}[PAUSE]${NC}  Waiting ${PAUSE_SECONDS}s before next experiment...\n"
            sleep "${PAUSE_SECONDS}"
        fi
    done

    local run_end
    run_end="$(date '+%Y-%m-%d %H:%M:%S')"

    # Generate combined report
    mkdir -p "${OUTPUT_DIR}"
    generate_combined_report "${OUTPUT_DIR}" "${run_start}" "${run_end}" "${total}" "${passed}" "${failed}"

    # Print summary
    echo -e "\n${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                    Orchestration Summary                     ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Total experiments: ${total}"
    echo -e "${BOLD}║${NC}  ${GREEN}Passed: ${passed}${NC}"
    echo -e "${BOLD}║${NC}  ${RED}Failed: ${failed}${NC}"
    echo -e "${BOLD}║${NC}  Report: ${OUTPUT_DIR}/combined-report-*.md"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

    # Exit with failure if any experiment failed
    [[ ${failed} -eq 0 ]]
}

main "$@"

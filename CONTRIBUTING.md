# Contributing to Chaos Engineering Toolkit

Thanks for your interest in contributing\! This document covers the development setup, coding standards, and pull request process.

## Development Setup

### Prerequisites

Install these tools before you begin:

- **Docker** 24+ — container runtime for Kind clusters
- **Kind** v0.20+ — local Kubernetes clusters
- **kubectl** v1.27+ — Kubernetes CLI
- **ShellCheck** — Bash linting (`apt install shellcheck` or `brew install shellcheck`)
- **BATS** — Bash test framework (`git clone https://github.com/bats-core/bats-core.git && cd bats-core && sudo ./install.sh /usr/local`)

### Getting Started

```bash
git clone https://github.com/shivajichaprana/chaos-engineering-toolkit.git
cd chaos-engineering-toolkit

# Run linting
make lint

# Run tests
make test

# Create a local cluster for manual testing
./scripts/setup-cluster.sh
```

## Coding Standards

### Shell Scripts

All shell scripts must follow these conventions:

- Start with `#\!/usr/bin/env bash` and `set -euo pipefail`
- Pass ShellCheck with no warnings (`shellcheck -x -s bash`)
- Include a header comment block describing the script's purpose
- Use `local` for function-scoped variables
- Quote all variable expansions (`"${var}"`, not `$var`)
- Use `log()` from the framework for output instead of raw `echo`
- Trap signals for cleanup in long-running scripts
- Add a usage function for scripts that accept arguments

### Experiment Scripts

When adding a new experiment:

1. Follow the structure in `docs/experiment-guide.md`
2. Implement both `experiment_inject()` and `experiment_rollback()`
3. Make rollback idempotent
4. Add a `config.yaml` and `README.md` in the experiment directory
5. Add BATS tests in `tests/`
6. Test against the sample app on a fresh Kind cluster

### YAML and Kubernetes Manifests

- Use 2-space indentation
- Include resource requests and limits on all containers
- Add meaningful labels (`app`, `component`, `part-of`)
- Include health probes (readiness and liveness) where applicable
- Validate with `kubeval --strict` before committing

## Testing

### Running Tests

```bash
# All tests
make test

# Specific test file
bats tests/test_experiment_runner.bats

# Lint only
make lint
```

### Writing Tests

- Place test files in `tests/` with the naming convention `test_<component>.bats`
- Test both success and failure paths
- Mock kubectl calls when testing logic (don't require a live cluster for unit tests)
- Keep tests fast — unit tests should complete in seconds

## Pull Request Process

1. **Fork** the repository and create a feature branch from `main`
2. **Write code** following the standards above
3. **Run checks** locally: `make lint && make test`
4. **Commit** using Conventional Commits format:
   - `feat(experiment-name): add new experiment for X`
   - `fix(runner): handle edge case when no pods match selector`
   - `docs(readme): update experiment catalog`
   - `test(node-drain): add validation for PDB compliance check`
   - `ci(workflow): add YAML validation step`
5. **Open a PR** with a clear description of what the change does and why
6. **Address review feedback** — all CI checks must pass before merge

## Commit Message Format

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]
```

Types: `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `chore`

Scope should be the experiment name, framework component, or area of change.

## Reporting Issues

Open a GitHub issue with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- Kind/kubectl/Docker versions
- Relevant logs or error output

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

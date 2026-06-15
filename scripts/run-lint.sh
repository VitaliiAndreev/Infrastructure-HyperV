#!/usr/bin/env bash
# Runs locally the same lint suite Common-Automation's reusable
# workflows run in this repo's CI - ci-bash.yml (shellcheck on the
# runner shims, check-sh-executable, bats) and ci-yaml.yml (actionlint,
# action-validator, yamllint, ansible-lint). Each check auto-skips when
# its surface is absent, so for this PowerShell module the suite is
# effectively lint-only - hence the name. The actual unit tests are
# Pester and live in scripts/Run-Tests.ps1; this runner never touches
# them, which is why it is NOT called run-tests.
#
# Single source of truth for the check logic lives in
# Common-Automation/scripts/run-tests.sh; this shim only points it at
# this repo via COMMON_AUTOMATION_TARGET_REPO. Common-Automation is
# expected as a sibling checkout under the same parent directory.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
common_automation_root="$(cd "${repo_root}/../Common-Automation" && pwd)"

COMMON_AUTOMATION_TARGET_REPO="${repo_root}" exec "${common_automation_root}/scripts/run-tests.sh"

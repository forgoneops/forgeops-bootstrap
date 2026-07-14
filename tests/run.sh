#!/usr/bin/env bash
# tests/run.sh - lint + smoke test entry point.
#
# Runs ShellCheck against every *.sh file in the repo, then runs the bats
# smoke tests in tests/*.bats (non-destructive: only exercises --help/--dry-run
# paths, never touches a real system). Requires `shellcheck` and `bats` on PATH.
#
# Usage: ./tests/run.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

FAIL=0

echo "== ShellCheck =="
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found on PATH — install it (apt install shellcheck) to run this gate." >&2
  FAIL=1
else
  while IFS= read -r -d '' f; do
    echo "-- ${f}"
    shellcheck -x "${f}" || FAIL=1
  done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)
fi

echo ""
echo "== bats smoke tests =="
if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found on PATH — install it (apt install bats) to run this gate." >&2
  FAIL=1
else
  bats "${REPO_ROOT}/tests" || FAIL=1
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo ""
  echo "All checks passed."
else
  echo ""
  echo "One or more checks failed — see output above." >&2
fi

exit "${FAIL}"

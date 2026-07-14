#!/usr/bin/env bats
# Smoke tests for the five entry points. Deliberately only exercise
# non-destructive paths (--help, --dry-run) so this suite is safe to run
# anywhere, including outside Ubuntu and without root.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

@test "install.sh --dry-run exits 0 and lists steps without requiring root" {
  run bash "${REPO_ROOT}/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"install_docker"* ]]
}

@test "install.sh --help exits 0" {
  run bash "${REPO_ROOT}/install.sh" --help
  [ "$status" -eq 0 ]
}

@test "install.sh rejects an unknown flag" {
  run bash "${REPO_ROOT}/install.sh" --not-a-real-flag
  [ "$status" -ne 0 ]
}

@test "verify.sh --help exits 0" {
  run bash "${REPO_ROOT}/verify.sh" --help
  [ "$status" -eq 0 ]
}

@test "uninstall.sh --dry-run exits 0 without requiring root" {
  run bash "${REPO_ROOT}/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENTS"* ]]
}

@test "uninstall.sh --help exits 0" {
  run bash "${REPO_ROOT}/uninstall.sh" --help
  [ "$status" -eq 0 ]
}

@test "migrate.sh --help exits 0" {
  run bash "${REPO_ROOT}/migrate.sh" --help
  [ "$status" -eq 0 ]
}

@test "migrate.sh requires a mode" {
  run bash "${REPO_ROOT}/migrate.sh" --host user@example.com
  [ "$status" -ne 0 ]
}

@test "update.sh --help exits 0" {
  run bash "${REPO_ROOT}/update.sh" --help
  [ "$status" -eq 0 ]
}

@test "backup.sh --help exits 0" {
  run bash "${REPO_ROOT}/scripts/backup.sh" --help
  [ "$status" -eq 0 ]
}

@test "restore.sh --help exits 0" {
  run bash "${REPO_ROOT}/scripts/restore.sh" --help
  [ "$status" -eq 0 ]
}

@test "restore.sh --list runs without a live install" {
  run bash "${REPO_ROOT}/scripts/restore.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available backups"* ]]
}

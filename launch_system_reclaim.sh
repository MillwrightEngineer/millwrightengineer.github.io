#!/usr/bin/env bash
set -euo pipefail

APP_NAME="System Reclaim"
DAYS=14
APPLY=0
EMPTY_TRASH=0
DOCKER_PRUNE=0
DOCKER_VOLUMES=0
OPEN_REPORT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${XDG_STATE_HOME:-"$HOME/.local/state"}/system-reclaim"
REPORT_FILE="$REPORT_DIR/reclaim-$(date +%Y%m%d-%H%M%S).log"

usage() {
  cat <<'USAGE'
System Reclaim launcher

Usage:
  ./launch_system_reclaim.sh [options]

Default mode is a dry run. It reports reclaim candidates without deleting files.

Options:
  --apply             Actually remove eligible cache files.
  --days N            Remove cache entries older than N days. Default: 14.
  --empty-trash       Empty the user's local Trash when --apply is set.
  --docker            Run docker system prune when --apply is set.
  --docker-volumes    Include unused Docker volumes. Requires --docker.
  --open-report       Open the report after the run when xdg-open is available.
  -h, --help          Show this help.

Examples:
  ./launch_system_reclaim.sh
  ./launch_system_reclaim.sh --apply --days 30
  ./launch_system_reclaim.sh --apply --empty-trash --docker
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_positive_integer() {
  case "$1" in
    ''|*[!0-9]*)
      die "--days must be a positive integer"
      ;;
    0)
      die "--days must be greater than zero"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --days)
      [[ $# -ge 2 ]] || die "--days requires a value"
      require_positive_integer "$2"
      DAYS="$2"
      shift 2
      ;;
    --empty-trash)
      EMPTY_TRASH=1
      shift
      ;;
    --docker)
      DOCKER_PRUNE=1
      shift
      ;;
    --docker-volumes)
      DOCKER_PRUNE=1
      DOCKER_VOLUMES=1
      shift
      ;;
    --open-report)
      OPEN_REPORT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

mkdir -p "$REPORT_DIR"
exec > >(tee -a "$REPORT_FILE") 2>&1

print_section() {
  printf '\n== %s ==\n' "$1"
}

path_size() {
  local path="$1"

  if [[ -e "$path" ]]; then
    du -sh "$path" 2>/dev/null | awk '{print $1}'
  else
    printf 'missing'
  fi
}

show_disk_snapshot() {
  print_section "$1"

  if command_exists df; then
    df -h "$HOME" 2>/dev/null || df -h .
  else
    printf 'df is not available on this system.\n'
  fi

  if command_exists free; then
    printf '\nMemory:\n'
    free -h
  fi
}

show_cache_candidates() {
  local candidates=(
    "$HOME/.cache/thumbnails"
    "$HOME/.cache/pip"
    "$HOME/.cache/yarn"
    "$HOME/.cache/go-build"
    "$HOME/.npm/_cacache"
    "$HOME/.local/share/Trash/files"
  )

  print_section "Reclaim candidates"
  printf '%-42s %s\n' "Path" "Size"
  printf '%-42s %s\n' "----" "----"

  local path
  for path in "${candidates[@]}"; do
    printf '%-42s %s\n' "$path" "$(path_size "$path")"
  done

  if command_exists docker; then
    printf '\nDocker is available. Use --docker with --apply to prune unused Docker data.\n'
  fi
}

clean_older_than() {
  local label="$1"
  local path="$2"

  if [[ ! -d "$path" ]]; then
    printf '%s: skipped, path not found: %s\n' "$label" "$path"
    return
  fi

  print_section "$label"

  if [[ "$APPLY" -eq 1 ]]; then
    printf 'Removing entries older than %s days from %s\n' "$DAYS" "$path"
    find "$path" -mindepth 1 -depth -mtime +"$DAYS" -exec rm -rf -- {} +
  else
    printf 'Dry run. Would remove entries older than %s days from %s\n' "$DAYS" "$path"
    find "$path" -mindepth 1 -depth -mtime +"$DAYS" -print 2>/dev/null | head -n 50 || true
  fi
}

empty_trash() {
  local trash_files="$HOME/.local/share/Trash/files"
  local trash_info="$HOME/.local/share/Trash/info"

  print_section "Trash"

  if [[ "$EMPTY_TRASH" -ne 1 ]]; then
    printf 'Skipped. Add --empty-trash with --apply to empty local Trash.\n'
    return
  fi

  if [[ "$APPLY" -ne 1 ]]; then
    printf 'Dry run. Would empty local Trash:\n'
    [[ -d "$trash_files" ]] && find "$trash_files" -mindepth 1 -maxdepth 1 -print 2>/dev/null | head -n 50 || true
    return
  fi

  [[ -d "$trash_files" ]] && find "$trash_files" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  [[ -d "$trash_info" ]] && find "$trash_info" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  printf 'Local Trash emptied.\n'
}

prune_docker() {
  print_section "Docker"

  if [[ "$DOCKER_PRUNE" -ne 1 ]]; then
    printf 'Skipped. Add --docker with --apply to prune unused Docker data.\n'
    return
  fi

  if ! command_exists docker; then
    printf 'Skipped. Docker is not installed or not on PATH.\n'
    return
  fi

  if [[ "$APPLY" -ne 1 ]]; then
    if [[ "$DOCKER_VOLUMES" -eq 1 ]]; then
      printf 'Dry run. Would run: docker system prune -f --volumes\n'
    else
      printf 'Dry run. Would run: docker system prune -f\n'
    fi
    return
  fi

  if [[ "$DOCKER_VOLUMES" -eq 1 ]]; then
    docker system prune -f --volumes
  else
    docker system prune -f
  fi
}

open_report_if_requested() {
  if [[ "$OPEN_REPORT" -ne 1 ]]; then
    return
  fi

  if command_exists xdg-open; then
    xdg-open "$REPORT_FILE" >/dev/null 2>&1 || true
  else
    printf 'xdg-open is not available. Report saved at %s\n' "$REPORT_FILE"
  fi
}

printf '%s\n' "$APP_NAME"
printf 'Script directory: %s\n' "$SCRIPT_DIR"
printf 'Mode: %s\n' "$([[ "$APPLY" -eq 1 ]] && printf 'apply' || printf 'dry run')"
printf 'Cache age threshold: %s days\n' "$DAYS"
printf 'Report: %s\n' "$REPORT_FILE"

show_disk_snapshot "Before"
show_cache_candidates

clean_older_than "Thumbnail cache" "$HOME/.cache/thumbnails"
clean_older_than "pip cache" "$HOME/.cache/pip"
clean_older_than "Yarn cache" "$HOME/.cache/yarn"
clean_older_than "Go build cache" "$HOME/.cache/go-build"
clean_older_than "npm cache" "$HOME/.npm/_cacache"
empty_trash
prune_docker

show_disk_snapshot "After"

print_section "Done"
printf 'Report saved at %s\n' "$REPORT_FILE"
if [[ "$APPLY" -eq 0 ]]; then
  printf 'No files were deleted. Re-run with --apply to reclaim eligible space.\n'
fi

open_report_if_requested

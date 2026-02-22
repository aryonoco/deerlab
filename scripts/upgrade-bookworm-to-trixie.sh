#!/usr/bin/env bash
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri
#===============================================================================
# upgrade-bookworm-to-trixie.sh - Debian 12 to 13 upgrade script
#
# DESCRIPTION:
#   Upgrades Debian 12 (Bookworm) to Debian 13 (Trixie).
#   Non-interactive and idempotent. Safe for unattended production use.
#
# REQUIREMENTS:
#   Bash 5.2+
#   Debian 12 Bookworm
#   Root privileges
#
# USAGE:
#   sudo ./upgrade-bookworm-to-trixie.sh
#   sudo ./upgrade-bookworm-to-trixie.sh --dry-run --verbose
#   sudo ./upgrade-bookworm-to-trixie.sh --services "ssh,nginx" --conffile-policy replace
#   sudo ./upgrade-bookworm-to-trixie.sh --force
#
# UPGRADE OPTIONS:
#   --services LIST          Comma-separated services to validate post-upgrade
#   --conffile-policy MODE   replace (default) or keep
#   --skip-reboot-check      Don't warn about reboot at end
#   --reset                  Clear step markers for a fresh run and exit
#
# GENERAL OPTIONS:
#   --dry-run                Preview without making changes
#   --verbose, -v            Enable verbose output
#   --trace-commands         Enable command-level tracing (DEBUG trap)
#   --syslog                 Also log to syslog (for enterprise environments)
#   --force, -f              Skip snapshot reminder pause
#   --help, -h               Show this help message
#
# ENVIRONMENT:
#   TRACE=1                  Enable bash debug tracing
#
# LICENSE:                   CPAL-1.0
#===============================================================================

# shellcheck enable=check-set-e-suppressed
# shellcheck enable=check-extra-masked-returns

#-------------------------------------------------------------------------------
# Bash Version Check
#-------------------------------------------------------------------------------
if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 2))); then
  printf 'Error: This script requires Bash 5.2+. Current: %s\n' "${BASH_VERSION}" >&2
  exit 1
fi

#-------------------------------------------------------------------------------
# Strict Mode & Safety Settings (Bash 5.2+)
#-------------------------------------------------------------------------------
set -o errexit             # Exit on any command failure
set -o errtrace            # ERR trap inherited by functions/subshells
set -o nounset             # Exit on undefined variable
set -o pipefail            # Catch errors in pipelines
shopt -s extglob           # Extended pattern matching
shopt -s globskipdots      # Never match . or .. in globs (Bash 5.2+)
shopt -s inherit_errexit   # Command substitutions inherit errexit (Bash 4.4+)
shopt -s assoc_expand_once # Prevent double array subscript evaluation (Bash 5.0+)

# Enable debug tracing if TRACE=1
[[ ${TRACE:-0} == 1 ]] && set -o xtrace

# Command-level tracing (set via --trace-commands)
declare TRACE_COMMANDS=false

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
declare -r SCRIPT_NAME="${0##*/}"
declare -r SCRIPT_VERSION="1.0.0"
declare -r LOG_FILE="/var/log/debian-upgrade-trixie.log"
declare -r LOCK_FILE="/var/lock/debian-upgrade-trixie.lock"

# Upgrade configuration
declare -r SOURCE_CODENAME="bookworm"
declare -r TARGET_CODENAME="trixie"
declare -r SOURCE_VERSION="12"
declare -r TARGET_VERSION="13"

# Network hosts for connectivity checks
declare -ra ALLOWED_NETWORK_HOSTS=(
  "deb.debian.org"
  "security.debian.org"
)

# Lock timeout (seconds) - prevents deadlocks from stuck processes
declare -ri LOCK_TIMEOUT=300

# Structured exit codes for better error handling
declare -ri EXIT_GENERAL_ERROR=1
declare -ri EXIT_LOCK_FAILED=2
declare -ri EXIT_INVALID_ARGS=3
declare -ri EXIT_ROOT_REQUIRED=4
declare -ri EXIT_WRONG_RELEASE=5
declare -ri EXIT_ALREADY_UPGRADED=6
declare -ri EXIT_NETWORK_ERROR=7
declare -ri EXIT_DISK_SPACE=8
declare -ri EXIT_VALIDATION_FAILED=9

# Required commands for script execution
declare -ra REQUIRED_COMMANDS=(
  apt apt-get apt-mark dpkg dpkg-query
  sed grep awk tee sleep flock pgrep fuser uname df curl
  getent mkdir rm mv cp chmod mktemp cut systemctl
)

# Minimum disk space required (MB)
declare -ri MIN_DISK_SPACE_MB=2048

# State directory for step markers and snapshots
declare -r STATE_DIR="/var/lib/debian-upgrade-trixie"

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
# Configuration (set by argument parsing, frozen by readonly in main)
declare DRY_RUN=false
declare VERBOSE=false
declare SYSLOG=false
declare FORCE=false
declare CONFFILE_POLICY="replace"
declare SKIP_REBOOT_CHECK=false
declare RESET=false
declare -a CRITICAL_SERVICES_LIST=()

# Cleanup state tracking (for rollback)
declare -i CLEANUP_IN_PROGRESS=0
declare -i SIGNAL_RECEIVED=0
declare RECEIVED_SIGNAL=""
declare -a CLEANUP_ACTIONS=()
declare -A CREATED_FILES=()
declare -A MODIFIED_FILES=()

#-------------------------------------------------------------------------------
# Terminal Colors
#-------------------------------------------------------------------------------
declare -A COLORS
if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
  COLORS=(
    [red]='\033[0;31m'
    [green]='\033[0;32m'
    [yellow]='\033[0;33m'
    [blue]='\033[0;34m'
    [cyan]='\033[0;36m'
    [bold]='\033[1m'
    [reset]='\033[0m'
  )
else
  COLORS=([red]='' [green]='' [yellow]='' [blue]='' [cyan]='' [bold]='' [reset]='')
fi

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
_log() {
  local -r level="$1" color="$2" msg="$3"
  local timestamp
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' "${EPOCHSECONDS}"
  printf '%b[%s]%b %s - %s\n' "${COLORS[${color}]}" "${level}" "${COLORS[reset]}" "${timestamp}" "${msg}" | tee -a "${LOG_FILE}"
  _syslog "${level}" "${msg}"
}

log_info() { _log "INFO " "blue" "$1"; }
log_success() { _log "OK   " "green" "$1"; }
log_warn() { _log "WARN " "yellow" "$1" >&2; }
log_error() { _log "ERROR" "red" "$1" >&2; }
log_debug() {
  if [[ ${VERBOSE} == true ]]; then
    _log "DEBUG" "cyan" "$1"
  fi
}

# Send to syslog if enabled
_syslog() {
  local -r level="$1" msg="$2"
  if [[ ${SYSLOG} == true ]] && command -v logger &>/dev/null; then
    logger -t "${SCRIPT_NAME}" -p "user.${level,,}" "${msg}" 2>/dev/null || true
  fi
}

log_step() {
  local -r step="$1" desc="$2"
  printf '\n%b%b[Step %s]%b %s\n' "${COLORS[bold]}" "${COLORS[blue]}" "${step}" "${COLORS[reset]}" "${desc}" | tee -a "${LOG_FILE}"
  printf '%s\n' "$(printf -- '-%.0s' {1..60})" | tee -a "${LOG_FILE}"
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
die() {
  log_error "$1"
  exit "${2:-1}"
}

# Check if command exists
has_command() {
  command -v "$1" &>/dev/null
}

# Detect if a sources file is an official Debian repository
# Checks multiple signals: URL, mirror+file scheme, keyring, suite+components
is_debian_repo() {
  local -r file="$1"
  # Direct URL match (debian.org or debian.net)
  grep -qiE 'debian\.org|debian\.net' "${file}" && return 0
  # mirror+file: URI scheme (Debian mirror list indirection)
  grep -qiE 'mirror\+file:' "${file}" && return 0
  # Signed by Debian archive keyring
  grep -qiE 'debian-archive-keyring' "${file}" && return 0
  # Standard Debian suites + components pattern
  grep -qiE '(Suites|deb\s).*\b(stable|testing|unstable|sid|bookworm|trixie|forky)\b' "${file}" \
    && grep -qiE '(Components:|main)' "${file}" && return 0
  return 1
}

# Execute or simulate based on dry-run mode
execute() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would execute: ${*@Q}"
    return 0
  fi
  log_debug "Executing: ${*@Q}"
  "$@"
}

# Non-interactive apt-get wrapper with conffile policy support
apt_get_noninteractive() {
  local -r conffile_policy="${1}"
  shift

  local -a dpkg_opts=()
  case "${conffile_policy}" in
    keep)
      dpkg_opts=(
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold"
      )
      ;;
    replace)
      dpkg_opts=(
        -o Dpkg::Options::="--force-confnew"
      )
      ;;
    none)
      # No dpkg options (for update, autoremove, clean)
      ;;
    *)
      die "Invalid conffile_policy: ${conffile_policy}" "${EXIT_INVALID_ARGS}"
      ;;
  esac

  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a \
    apt-get -y -qq \
      "${dpkg_opts[@]}" \
      -o Acquire::Retries=3 \
      "$@"
}

# Validate required commands are available (fail-fast)
validate_required_commands() {
  log_info "Validating required commands..."

  local -a missing=()
  local cmd

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log_error "Missing required command(s): ${missing[*]}"
    die "Install missing commands and try again" "${EXIT_GENERAL_ERROR}"
  fi

  log_success "All required commands available"
}

#-------------------------------------------------------------------------------
# Lock Management
#-------------------------------------------------------------------------------
acquire_lock() {
  log_debug "Acquiring lock: ${LOCK_FILE}"

  mkdir -p "${LOCK_FILE%/*}"

  # Open lock file
  exec {LOCK_FD}>"${LOCK_FILE}"

  if ! flock -w "${LOCK_TIMEOUT}" "${LOCK_FD}"; then
    die "Could not acquire lock within ${LOCK_TIMEOUT}s. Another instance may be stuck." "${EXIT_LOCK_FAILED}"
  fi

  # Write PID for debugging
  printf '%d\n' $$ >&"${LOCK_FD}"
  log_debug "Lock acquired (PID: $$)"

  # Register lock release as cleanup action
  register_cleanup "release_lock"
}

release_lock() {
  if [[ -v LOCK_FD ]]; then
    exec {LOCK_FD}>&- 2>/dev/null || true
    log_debug "Lock released"
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Action Registry
#-------------------------------------------------------------------------------
register_cleanup() {
  local -r action="$1"
  CLEANUP_ACTIONS+=("${action}")
  log_debug "Registered cleanup action: ${action}"
}

register_created_file() {
  local -r file="$1"
  CREATED_FILES["${file}"]=1
  log_debug "Registered created file: ${file}"
}

register_modified_file() {
  local -r file="$1" backup="$2"
  MODIFIED_FILES["${file}"]="${backup}"
  log_debug "Registered modified file: ${file} (backup: ${backup})"
}

backup_file() {
  local -r file="$1"
  if [[ -f ${file} ]]; then
    local -r backup="${file}.bak.${SRANDOM}"
    cp -a "${file}" "${backup}" 2>/dev/null || true
    register_modified_file "${file}" "${backup}"
    echo "${backup}"
  fi
}

# Atomic file write
atomic_write() {
  local -r target="$1"
  local -r content="$2"
  local temp

  # Create temp file securely with mktemp (atomic creation with O_EXCL)
  temp=$(mktemp "${target}.tmp.XXXXXX") || die "Failed to create temp file for ${target}" "${EXIT_GENERAL_ERROR}"

  # Clean up temp file on function exit
  trap 'rm -f "${temp}" 2>/dev/null; trap - RETURN' RETURN

  # Write to temp file first
  printf '%s\n' "${content}" >"${temp}"

  # Atomic rename
  mv -f "${temp}" "${target}"

  # Clear trap and register for rollback tracking
  trap - RETURN
  register_created_file "${target}"
}

#-------------------------------------------------------------------------------
# Signal Definitions & Exit Codes
#-------------------------------------------------------------------------------
declare -rA SIGNAL_INFO=(
  # Graceful termination signals
  [HUP]="1:Hangup:graceful"
  [INT]="2:Interrupt:graceful"
  [QUIT]="3:Quit:graceful"
  [TERM]="15:Terminated:graceful"

  # Program error signals
  [ILL]="4:Illegal instruction:fatal"
  [TRAP]="5:Trace/breakpoint trap:fatal"
  [ABRT]="6:Aborted:fatal"
  [BUS]="7:Bus error:fatal"
  [FPE]="8:Floating point exception:fatal"
  [SEGV]="11:Segmentation fault:fatal"
  [STKFLT]="16:Stack fault:fatal"
  [SYS]="31:Bad system call:fatal"
  [IOT]="6:IOT trap:fatal"
)

#-------------------------------------------------------------------------------
# Signal Handler
#-------------------------------------------------------------------------------
signal_handler() {
  local -r sig_name="${1:-UNKNOWN}"
  local sig_num=1 sig_desc="Unknown signal" sig_type="fatal"

  # Prevent re-entrant signal handling
  if ((SIGNAL_RECEIVED)); then
    return
  fi
  SIGNAL_RECEIVED=1
  RECEIVED_SIGNAL="${sig_name}"

  # Parse signal info
  if [[ -v SIGNAL_INFO[${sig_name}] ]]; then
    IFS=':' read -r sig_num sig_desc sig_type <<<"${SIGNAL_INFO[${sig_name}]}"
  fi

  local -ri exit_code=$((128 + sig_num))

  # Log based on signal type
  case "${sig_type}" in
    graceful)
      log_warn "Received SIG${sig_name} (${sig_desc}) - initiating graceful shutdown..."
      ;;
    fatal)
      log_error "FATAL: Received SIG${sig_name} (${sig_desc}) - attempting emergency cleanup..."
      log_error "This indicates a serious error. Please report if reproducible."
      ;;
    *)
      log_warn "Unknown signal type: ${sig_type}"
      ;;
  esac

  # Perform cleanup (will be handled by EXIT trap)
  exit "${exit_code}"
}

#-------------------------------------------------------------------------------
# Error Handler
#-------------------------------------------------------------------------------
error_handler() {
  local -ri exit_code=$?
  local -r failed_cmd="${BASH_COMMAND}"
  local -r line="${BASH_LINENO[0]}"
  local -r func="${FUNCNAME[1]:-main}"
  local -r src="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

  # Don't trigger for intentional failures
  ((exit_code == 0)) && return 0

  log_error "Command failed with exit code ${exit_code}"
  log_error "  Location: ${func}() at ${src}:${line}"
  log_error "  Command:  ${failed_cmd}"

  # Print stack trace and state in verbose mode
  if [[ ${VERBOSE} == true ]]; then
    log_debug "Stack trace:"
    local -i i
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      log_debug "  [${i}] ${FUNCNAME[i]}() at ${BASH_SOURCE[i]:-unknown}:${BASH_LINENO[i - 1]}"
    done

    # Show key variable state for debugging
    log_debug "Variable state:"
    log_debug "  DRY_RUN=${DRY_RUN:-unset}"
    log_debug "  CONFFILE_POLICY=${CONFFILE_POLICY:-unset}"
    log_debug "  SOURCE_CODENAME=${SOURCE_CODENAME:-unset}"
    log_debug "  TARGET_CODENAME=${TARGET_CODENAME:-unset}"
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Handler (runs on EXIT - catches all termination scenarios)
# Performs cleanup in LIFO order, handles rollback of partial changes
#-------------------------------------------------------------------------------
# Kill any child processes in our process group
cleanup_processes() {
  # Get list of child processes
  local -a child_pids
  mapfile -t child_pids < <(pgrep -P $$ 2>/dev/null || true)

  if ((${#child_pids[@]} > 0)); then
    log_debug "Terminating ${#child_pids[@]} child process(es)"
    for pid in "${child_pids[@]}"; do
      kill -TERM "${pid}" 2>/dev/null || true
    done
    # Brief wait for graceful termination
    sleep 0.5
    # Force kill any remaining
    for pid in "${child_pids[@]}"; do
      kill -KILL "${pid}" 2>/dev/null || true
    done
  fi
}

cleanup() {
  local -ri original_exit_code=${?}
  local -i exit_code=${original_exit_code}

  # Prevent recursive cleanup
  if ((CLEANUP_IN_PROGRESS)); then
    return
  fi
  CLEANUP_IN_PROGRESS=1

  # Disable errexit/pipefail so logging failures (e.g. tee on read-only FS)
  # cannot abort cleanup mid-execution
  set +o errexit
  set +o pipefail

  # Disable all signal traps during cleanup to prevent interruption
  trap '' INT TERM HUP QUIT

  log_debug "Cleanup triggered (exit_code=${exit_code}, signal=${RECEIVED_SIGNAL:-none})"

  # Terminate any child processes first
  cleanup_processes

  # If we received a fatal signal, adjust messaging
  if [[ -n ${RECEIVED_SIGNAL} ]]; then
    log_info "Cleaning up after SIG${RECEIVED_SIGNAL}..."
  fi

  # Execute registered cleanup actions in reverse order (LIFO)
  local -i i
  for ((i = ${#CLEANUP_ACTIONS[@]} - 1; i >= 0; i--)); do
    local action="${CLEANUP_ACTIONS[i]}"
    log_debug "Executing cleanup action: ${action}"
    if declare -F "${action}" &>/dev/null; then
      "${action}" 2>/dev/null || true
    else
      log_warn "Unknown cleanup action skipped: ${action}"
    fi
  done

  # Rollback: Remove files we created (if exit was not successful)
  if ((exit_code != 0)); then
    log_info "Rolling back changes..."

    for file in "${!CREATED_FILES[@]}"; do
      if [[ -f ${file} ]]; then
        log_debug "Removing created file: ${file}"
        rm -f "${file}" 2>/dev/null || true
      fi
    done

    # Restore modified files from backups
    for file in "${!MODIFIED_FILES[@]}"; do
      local backup="${MODIFIED_FILES[${file}]}"
      if [[ -f ${backup} ]]; then
        log_debug "Restoring ${file} from ${backup}"
        mv -f "${backup}" "${file}" 2>/dev/null || true
      fi
    done

    # Clean up apt/dpkg state if we were mid-operation
    # Uses command -v directly (builtin) to avoid SC2310 with has_command (function)
    if command -v apt-get &>/dev/null; then
      log_debug "Attempting dpkg recovery..."
      dpkg --configure -a 2>/dev/null || true
      # Only remove lock files if no other apt process holds them
      if ! command -v fuser &>/dev/null; then
        log_warn "fuser not found (psmisc not installed) — skipping lock cleanup for safety"
      elif ! fuser /var/lib/dpkg/lock &>/dev/null 2>&1; then
        rm -f /var/lib/apt/lists/lock 2>/dev/null || true
        rm -f /var/lib/dpkg/lock* 2>/dev/null || true
        rm -f /var/cache/apt/archives/lock 2>/dev/null || true
      else
        log_warn "Another apt process holds locks — skipping lock cleanup"
      fi
    fi
  else
    # Success: remove backup files
    for file in "${!MODIFIED_FILES[@]}"; do
      local backup="${MODIFIED_FILES[${file}]}"
      rm -f "${backup}" 2>/dev/null || true
    done
  fi

  # Final status
  if ((exit_code != 0)); then
    log_error "Script failed with exit code: ${exit_code}"
    [[ -n ${RECEIVED_SIGNAL} ]] && log_error "Terminated by: SIG${RECEIVED_SIGNAL}"
    log_info "Log file: ${LOG_FILE}"
  fi

  exit "${exit_code}"
}

#-------------------------------------------------------------------------------
# Setup Signal Handlers
#-------------------------------------------------------------------------------
setup_signal_handlers() {
  # EXIT trap - always runs, handles all cleanup
  trap cleanup EXIT

  # ERR trap - provides error context
  trap error_handler ERR

  # Graceful termination signals
  trap 'signal_handler HUP' HUP   # 1  - Hangup
  trap 'signal_handler INT' INT   # 2  - Interrupt (Ctrl+C)
  trap 'signal_handler QUIT' QUIT # 3  - Quit (Ctrl+\)
  trap 'signal_handler TERM' TERM # 15 - Termination request

  # Program error signals (fatal - attempt cleanup)
  trap 'signal_handler ILL' ILL                           # 4  - Illegal instruction
  trap 'signal_handler TRAP' TRAP                         # 5  - Trace/breakpoint trap
  trap 'signal_handler ABRT' ABRT                         # 6  - Abort
  trap 'signal_handler BUS' BUS                           # 7  - Bus error
  trap 'signal_handler FPE' FPE                           # 8  - Floating point exception
  trap 'signal_handler SEGV' SEGV                         # 11 - Segmentation fault
  trap 'signal_handler SYS' SYS                           # 31 - Bad system call
  trap 'signal_handler STKFLT' STKFLT 2>/dev/null || true # 16 - Stack fault
  # These are not widely available. Attempt to trap but ignore failure
  trap 'signal_handler EMT' EMT 2>/dev/null || true
  trap 'signal_handler IOT' IOT 2>/dev/null || true

  log_debug "Signal handlers installed"
}

#-------------------------------------------------------------------------------
# Debug Tracing (--trace-commands)
#-------------------------------------------------------------------------------
setup_debug_tracing() {
  if [[ ${TRACE_COMMANDS} == true ]]; then
    trap '_trace_command "${BASH_COMMAND}" "${LINENO}" "${FUNCNAME[0]:-main}"' DEBUG
    log_debug "Command tracing enabled"
  fi
}

_trace_command() {
  local -r cmd="$1" line="$2" func="$3"
  # Skip internal tracing functions to avoid recursion
  [[ ${cmd} == _trace_command* || ${cmd} == log_* ]] && return
  log_debug "[${func}:${line}] ${cmd}"
}

#-------------------------------------------------------------------------------
# Step Markers (Idempotency Support)
#-------------------------------------------------------------------------------

# Check if a step was previously completed
step_completed() {
  local -r step_name="$1"
  [[ -f "${STATE_DIR}/.step_${step_name}" ]]
}

# Mark a step as completed
mark_step_complete() {
  local -r step_name="$1"
  if [[ ${DRY_RUN} != true ]]; then
    mkdir -p "${STATE_DIR}"
    printf '%s\n' "$(printf '%(%FT%T)T' "${EPOCHSECONDS}")" >"${STATE_DIR}/.step_${step_name}"
  fi
  log_debug "Step '${step_name}' marked complete"
}

# Clear all step markers (for fresh run)
clear_step_markers() {
  if [[ -d ${STATE_DIR} ]]; then
    rm -f "${STATE_DIR}"/.step_* 2>/dev/null || true
    log_debug "Step markers cleared"
  fi
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
check_root() {
  ((EUID == 0)) || die "This script must be run as root. Use: sudo ${SCRIPT_NAME}" "${EXIT_ROOT_REQUIRED}"
}

check_current_release() {
  log_info "Checking current Debian release..."

  [[ -f /etc/os-release ]] || die "Cannot detect release: /etc/os-release not found" "${EXIT_WRONG_RELEASE}"

  # shellcheck source=/dev/null
  source /etc/os-release

  local -r current_codename="${VERSION_CODENAME:-}"

  case "${current_codename}" in
    "${TARGET_CODENAME}")
      log_success "System already running ${TARGET_CODENAME} (${PRETTY_NAME:-})"
      exit "${EXIT_ALREADY_UPGRADED}"
      ;;
    "${SOURCE_CODENAME}")
      log_success "Current release: ${current_codename} (Debian ${VERSION_ID:-${SOURCE_VERSION}})"
      ;;
    *)
      die "Unexpected release: '${current_codename}'. Expected '${SOURCE_CODENAME}'." "${EXIT_WRONG_RELEASE}"
      ;;
  esac
}

check_disk_space() {
  log_info "Checking available disk space..."
  local -ri required_mb="${MIN_DISK_SPACE_MB}"
  local -i available_mb
  available_mb=$(df -BM / 2>/dev/null | awk 'NR==2 {print int($4)}') || available_mb=0

  if ((available_mb < required_mb)); then
    die "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required on /" "${EXIT_DISK_SPACE}"
  fi
  log_success "Disk space OK: ${available_mb}MB available (${required_mb}MB required)"
}

check_dns() {
  log_info "Checking DNS resolution..."
  local host
  for host in "${ALLOWED_NETWORK_HOSTS[@]}"; do
    if ! getent hosts "${host}" &>/dev/null; then
      die "DNS resolution failed for ${host}. Check your DNS settings." "${EXIT_NETWORK_ERROR}"
    fi
    log_debug "DNS OK: ${host}"
  done
  log_success "DNS resolution OK"
}

check_file_descriptors() {
  log_info "Checking file descriptor limits..."
  local -ri required_fds=256
  local -i max_fds
  max_fds=$(ulimit -n 2>/dev/null) || max_fds=0

  if ((max_fds > 0 && max_fds < required_fds)); then
    log_warn "Low file descriptor limit: ${max_fds} (recommended: ${required_fds}+)"
  else
    log_debug "File descriptor limit: ${max_fds}"
  fi
}

check_held_packages() {
  log_info "Checking for held packages..."

  local -a held
  # shellcheck disable=SC2312 # Failures intentionally masked; empty result is handled below
  mapfile -t held < <(dpkg --get-selections 2>/dev/null | awk '/hold$/{print $1}')

  if ((${#held[@]} > 0)); then
    log_warn "Found ${#held[@]} held package(s): ${held[*]}"
    log_warn "Held packages may cause upgrade issues"
  else
    log_success "No held packages"
  fi
}

check_network() {
  log_info "Checking network connectivity..."

  local host
  for host in "${ALLOWED_NETWORK_HOSTS[@]}"; do
    if ! curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "https://${host}" 2>/dev/null; then
      die "Cannot reach ${host}. Check network connectivity." "${EXIT_NETWORK_ERROR}"
    fi
    log_debug "Reachable: ${host}"
  done

  log_success "Network connectivity confirmed"
}

check_third_party_repos() {
  log_info "Checking for third-party repositories..."

  local -a third_party=()
  local file

  for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f ${file} ]] || continue
    # Skip files that reference Debian official repos
    # shellcheck disable=SC2310 # intentional: branching on return value
    if ! is_debian_repo "${file}"; then
      third_party+=("${file}")
    fi
  done

  if ((${#third_party[@]} > 0)); then
    log_warn "Found ${#third_party[@]} third-party source(s):"
    local f
    for f in "${third_party[@]}"; do
      log_warn "  ${f}"
    done
    log_warn "Third-party repos will NOT be modified - review after upgrade"
  else
    log_success "No third-party repositories found"
  fi
}

check_snapshot_reminder() {
  if [[ ${FORCE} == true || ${DRY_RUN} == true ]]; then
    return 0
  fi

  log_warn "==========================================================="
  log_warn "  IMPORTANT: Ensure you have a VM/VPS snapshot or backup"
  log_warn "  before proceeding with this major version upgrade."
  log_warn "  This is your last chance to abort (Ctrl+C)."
  log_warn "==========================================================="
  log_info "Continuing in 10 seconds..."
  sleep 10
}

#-------------------------------------------------------------------------------
# Phase Functions
#-------------------------------------------------------------------------------

# Phase 1/8: Pre-flight checks
phase_preflight() {
  log_step "1/8" "Pre-flight checks"

  if [[ -f "${STATE_DIR}/.step_preflight" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  check_root
  check_current_release
  check_disk_space
  check_file_descriptors
  check_held_packages
  validate_required_commands
  check_dns
  check_network
  check_third_party_repos
  check_snapshot_reminder

  mark_step_complete "preflight"
  log_success "Pre-flight checks passed"
}

# Phase 2/8: Snapshot package state
phase_snapshot_state() {
  log_step "2/8" "Snapshotting current package state"

  if [[ -f "${STATE_DIR}/.step_snapshot_state" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  execute mkdir -p "${STATE_DIR}"

  if [[ ${DRY_RUN} != true ]]; then
    log_info "Saving package selections..."
    dpkg --get-selections > "${STATE_DIR}/selections-pre.txt" 2>/dev/null || true

    log_info "Saving manually installed packages..."
    apt-mark showmanual > "${STATE_DIR}/manual-packages-pre.txt" 2>/dev/null || true

    log_info "Saving package versions..."
    dpkg-query -W -f='${Package}\t${Version}\n' > "${STATE_DIR}/package-versions-pre.txt" 2>/dev/null || true

    log_info "Backing up APT sources..."
    cp -a /etc/apt/sources.list "${STATE_DIR}/sources.list.pre" 2>/dev/null || true
    if [[ -d /etc/apt/sources.list.d ]]; then
      cp -a /etc/apt/sources.list.d "${STATE_DIR}/sources.list.d.pre" 2>/dev/null || true
    fi
  else
    log_info "[DRY-RUN] Would save package state snapshots to ${STATE_DIR}/"
  fi

  mark_step_complete "snapshot_state"
  log_success "Package state snapshot saved to ${STATE_DIR}"
}

# Phase 3/8: Update current release
phase_update_bookworm() {
  log_step "3/8" "Updating current ${SOURCE_CODENAME} installation"

  if [[ -f "${STATE_DIR}/.step_update_bookworm" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  log_info "Refreshing package index..."
  execute apt_get_noninteractive none update

  log_info "Upgrading packages within ${SOURCE_CODENAME}..."
  execute apt_get_noninteractive keep upgrade

  log_info "Performing dist-upgrade within ${SOURCE_CODENAME}..."
  execute apt_get_noninteractive keep dist-upgrade

  mark_step_complete "update_bookworm"
  log_success "Current ${SOURCE_CODENAME} installation fully updated"
}

# Phase 4/8: Switch APT sources
phase_switch_sources() {
  log_step "4/8" "Switching APT sources from ${SOURCE_CODENAME} to ${TARGET_CODENAME}"

  if [[ -f "${STATE_DIR}/.step_switch_sources" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  local -i modified=0

  # Clean up orphaned backup files from prior failed runs
  if [[ ${DRY_RUN} != true ]]; then
    local -a stale_backups=()
    local bf
    for bf in /etc/apt/sources.list.bak.* /etc/apt/sources.list.d/*.bak.*; do
      [[ -f ${bf} ]] || continue
      stale_backups+=("${bf}")
    done
    if ((${#stale_backups[@]} > 0)); then
      log_warn "Removing ${#stale_backups[@]} orphaned backup file(s) from prior run(s)"
      for bf in "${stale_backups[@]}"; do
        log_debug "  Removing stale backup: ${bf}"
        rm -f "${bf}" 2>/dev/null || true
      done
    fi
  fi

  # Process /etc/apt/sources.list
  if [[ -f /etc/apt/sources.list ]] && grep -q "${SOURCE_CODENAME}" /etc/apt/sources.list; then
    log_info "Updating /etc/apt/sources.list..."
    [[ ${DRY_RUN} != true ]] && backup_file "/etc/apt/sources.list"
    execute sed -i "s/${SOURCE_CODENAME}/${TARGET_CODENAME}/g" /etc/apt/sources.list
    ((++modified))
  fi

  # Process files in sources.list.d/ (both .list and .sources formats)
  local file
  for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f ${file} ]] || continue
    grep -q "${SOURCE_CODENAME}" "${file}" || continue

    # Only modify Debian-official repos
    # shellcheck disable=SC2310 # intentional: branching on return value
    if is_debian_repo "${file}"; then
      log_info "Updating ${file}..."
      [[ ${DRY_RUN} != true ]] && backup_file "${file}"
      execute sed -i "s/${SOURCE_CODENAME}/${TARGET_CODENAME}/g" "${file}"
      ((++modified))
    else
      log_warn "Skipping non-Debian repo: ${file}"
    fi
  done

  if ((modified == 0)); then
    die "No sources files found containing '${SOURCE_CODENAME}'" "${EXIT_VALIDATION_FAILED}"
  fi

  log_info "Modified ${modified} source file(s)"

  # Verify new sources work
  log_info "Verifying new sources with apt-get update..."
  execute apt_get_noninteractive none update

  mark_step_complete "switch_sources"
  log_success "APT sources switched to ${TARGET_CODENAME}"
}

# Phase 5/8: Safe first-pass upgrade
phase_minimal_upgrade() {
  log_step "5/8" "Performing minimal upgrade (no removals)"

  if [[ -f "${STATE_DIR}/.step_minimal_upgrade" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  execute apt_get_noninteractive "${CONFFILE_POLICY}" upgrade

  mark_step_complete "minimal_upgrade"
  log_success "Minimal upgrade complete"
}

# Phase 6/8: Full upgrade
phase_full_upgrade() {
  log_step "6/8" "Performing full upgrade"

  if [[ -f "${STATE_DIR}/.step_full_upgrade" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  execute apt_get_noninteractive "${CONFFILE_POLICY}" full-upgrade

  mark_step_complete "full_upgrade"
  log_success "Full upgrade complete"
}

# Phase 7/8: Post-upgrade cleanup
phase_post_cleanup() {
  log_step "7/8" "Post-upgrade cleanup"

  if [[ -f "${STATE_DIR}/.step_post_cleanup" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  log_info "Removing obsolete packages..."
  execute apt_get_noninteractive none autoremove --purge

  log_info "Cleaning package cache..."
  execute apt-get clean

  log_info "Modernizing APT sources to DEB822 format..."
  if ! apt modernize-sources --help &>/dev/null; then
    log_info "apt modernize-sources not available — upgrading apt package..."
    execute apt_get_noninteractive "${CONFFILE_POLICY}" install --only-upgrade apt
  fi
  # shellcheck disable=SC2310 # Intentionally non-fatal: set -e suppression is the goal
  execute apt modernize-sources || log_warn "apt modernize-sources failed — skipping DEB822 migration (non-fatal)"

  log_info "Saving post-upgrade package state..."
  dpkg --get-selections > "${STATE_DIR}/selections-post.txt" 2>/dev/null || true
  dpkg-query -W -f='${Package}\t${Version}\n' > "${STATE_DIR}/package-versions-post.txt" 2>/dev/null || true
  apt-mark showmanual > "${STATE_DIR}/manual-packages-post.txt" 2>/dev/null || true

  mark_step_complete "post_cleanup"
  log_success "Post-upgrade cleanup complete"
}

# Phase 8/8: Post-upgrade validation
phase_post_validation() {
  log_step "8/8" "Post-upgrade validation"

  if [[ -f "${STATE_DIR}/.step_post_validation" ]]; then
    log_info "Step already completed - skipping"
    return 0
  fi

  local -i issues=0

  # 1. Verify release codename
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ ${VERSION_CODENAME:-} == "${TARGET_CODENAME}" ]]; then
    log_success "Release: ${PRETTY_NAME:-${TARGET_CODENAME}}"
  else
    log_error "Expected ${TARGET_CODENAME}, got ${VERSION_CODENAME:-unknown}"
    ((++issues))
  fi

  # 2. dpkg audit
  local audit_output
  audit_output=$(dpkg --audit 2>/dev/null) || true
  if [[ -z ${audit_output} ]]; then
    log_success "dpkg audit: clean"
  else
    log_warn "dpkg audit found issues:"
    log_warn "  ${audit_output%%$'\n'*}"
    ((++issues))
  fi

  # 3. Fix broken dependencies
  log_info "Checking for broken dependencies..."
  execute apt_get_noninteractive none install -f

  # 4. Check critical services (from --services flag)
  if ((${#CRITICAL_SERVICES_LIST[@]} > 0)); then
    log_info "Checking critical services..."
    local svc
    for svc in "${CRITICAL_SERVICES_LIST[@]}"; do
      if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        log_success "Service ${svc}: active"
      else
        log_error "Service ${svc}: NOT active"
        ((++issues))
      fi
    done
  fi

  # 5. Kernel version
  # shellcheck disable=SC2312 # Informational only; uname failure is not actionable
  log_info "Running kernel: $(uname -r)"

  # 6. needrestart check (if available)
  # Uses command -v directly (builtin) to avoid SC2310
  if command -v needrestart &>/dev/null; then
    log_info "Checking for services needing restart..."
    needrestart -b 2>/dev/null || true
  fi

  # 7. Reboot guidance
  if [[ ${SKIP_REBOOT_CHECK} != true ]]; then
    if [[ -f /var/run/reboot-required ]]; then
      log_warn "REBOOT REQUIRED: A reboot is needed to complete the upgrade"
    else
      log_info "No reboot-required marker found (reboot still recommended after major upgrade)"
    fi
  fi

  if ((issues > 0)); then
    log_warn "Post-validation completed with ${issues} issue(s)"
  else
    log_success "Post-validation passed"
  fi

  mark_step_complete "post_validation"
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    UPGRADE COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "Upgrade: Debian ${SOURCE_VERSION} (${SOURCE_CODENAME}) -> Debian ${TARGET_VERSION} (${TARGET_CODENAME})"
  log_info "Conffile policy: ${CONFFILE_POLICY}"
  log_info "Log file: ${LOG_FILE}"
  log_info "State directory: ${STATE_DIR}"
  log_info ""

  if [[ ${SKIP_REBOOT_CHECK} != true ]]; then
    log_warn "A reboot is strongly recommended after a major version upgrade:"
    log_warn "  sudo reboot"
  fi
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}${SCRIPT_NAME}${COLORS[reset]} v${SCRIPT_VERSION} - Debian ${SOURCE_CODENAME} to ${TARGET_CODENAME} upgrade

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo ${SCRIPT_NAME} [OPTIONS]

${COLORS[bold]}UPGRADE OPTIONS:${COLORS[reset]}
    --services LIST          Comma-separated services to validate post-upgrade
                             (e.g., "ssh,nginx,postgresql")
    --conffile-policy MODE   How to handle changed config files:
                               replace (default) - install package maintainer's version
                               keep - preserve existing configs
    --skip-reboot-check      Don't warn about reboot at end
    --reset                  Clear step markers for a fresh run and exit

${COLORS[bold]}GENERAL OPTIONS:${COLORS[reset]}
    --dry-run                Preview without making changes
    --verbose, -v            Enable verbose output
    --trace-commands         Enable command-level tracing (DEBUG trap)
    --syslog                 Also log to syslog (for enterprise environments)
    --force, -f              Skip snapshot reminder pause
    --help, -h               Show this help

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    # Preview upgrade
    sudo ${SCRIPT_NAME} --dry-run --verbose

    # Standard upgrade (install new configs)
    sudo ${SCRIPT_NAME}

    # Upgrade keeping existing configs and service checks
    sudo ${SCRIPT_NAME} --conffile-policy keep --services "ssh,nginx"

    # Unattended upgrade (no pause)
    sudo ${SCRIPT_NAME} --force

${COLORS[bold]}IDEMPOTENCY:${COLORS[reset]}
    Step markers in ${STATE_DIR} allow safe re-runs.
    Interrupted upgrades resume from the last incomplete phase.

${COLORS[bold]}ENVIRONMENT:${COLORS[reset]}
    TRACE=1    Enable debug tracing

${COLORS[bold]}LOG:${COLORS[reset]}
    ${LOG_FILE}

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_arguments() {
  while (($#)); do
    case "${1}" in
      --services)
        [[ -n ${2:-} ]] || die "--services requires LIST (e.g., \"ssh,nginx\")" "${EXIT_INVALID_ARGS}"
        IFS=',' read -ra CRITICAL_SERVICES_LIST <<<"${2}"
        shift 2
        ;;
      --services=*)
        IFS=',' read -ra CRITICAL_SERVICES_LIST <<<"${1#*=}"
        shift
        ;;
      --conffile-policy)
        [[ -n ${2:-} ]] || die "--conffile-policy requires MODE (keep or replace)" "${EXIT_INVALID_ARGS}"
        CONFFILE_POLICY="${2}"
        shift 2
        ;;
      --conffile-policy=*)
        CONFFILE_POLICY="${1#*=}"
        shift
        ;;
      --skip-reboot-check)
        SKIP_REBOOT_CHECK=true
        shift
        ;;
      --reset)
        RESET=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --verbose | -v)
        VERBOSE=true
        shift
        ;;
      --trace-commands)
        TRACE_COMMANDS=true
        shift
        ;;
      --syslog)
        SYSLOG=true
        shift
        ;;
      --force | -f)
        FORCE=true
        shift
        ;;
      --help | -h)
        show_help
        exit 0
        ;;
      -*)
        die "Unknown option: ${1} (use --help)" "${EXIT_INVALID_ARGS}"
        ;;
      *)
        die "Unexpected argument: ${1} (use --help)" "${EXIT_INVALID_ARGS}"
        ;;
    esac
  done

  # Validate conffile policy
  case "${CONFFILE_POLICY}" in
    keep | replace) ;;
    *) die "Invalid --conffile-policy: '${CONFFILE_POLICY}'. Must be 'keep' or 'replace'." "${EXIT_INVALID_ARGS}" ;;
  esac
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  mkdir -p "${LOG_FILE%/*}"
  : >>"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  Debian Upgrade: ${SOURCE_CODENAME} -> ${TARGET_CODENAME} v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"
  [[ ${TRACE_COMMANDS} == true ]] && log_warn "TRACE MODE: Command tracing enabled"

  setup_signal_handlers
  setup_debug_tracing

  # Freeze configuration to prevent modification
  readonly DRY_RUN VERBOSE SYSLOG TRACE_COMMANDS FORCE CONFFILE_POLICY SKIP_REBOOT_CHECK RESET
  readonly -a CRITICAL_SERVICES_LIST

  # Handle --reset: clear step markers and exit
  if [[ ${RESET} == true ]]; then
    clear_step_markers
    log_success "Step markers cleared. Next run will start fresh."
    exit 0
  fi

  acquire_lock

  # Execute phases
  phase_preflight
  phase_snapshot_state
  phase_update_bookworm
  phase_switch_sources
  phase_minimal_upgrade
  phase_full_upgrade
  phase_post_cleanup
  phase_post_validation

  print_summary

  log_success "Upgrade completed successfully!"
}

#-------------------------------------------------------------------------------
# Entry Point
#-------------------------------------------------------------------------------
parse_arguments "$@"
main

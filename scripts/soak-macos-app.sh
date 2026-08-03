#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  soak-macos-app.sh --app PATH [options]

Required:
  --app PATH                 macOS application bundle to soak

Options:
  --cycles COUNT             launch/termination cycles (default: 10)
  --startup-timeout SECONDS  time to wait for both shells (default: 15)
  --shutdown-timeout SECONDS time to wait for clean shutdown (default: 10)
  --artifacts PATH           failure diagnostics directory
                             (default: ./soak-artifacts)
  -h, --help                 show this help

The bundle executable is launched directly. Each cycle gets an isolated HOME
and ZDOTDIR with a controlled .zshrc. No Accessibility permission is needed.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_value() {
    [[ "$#" -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

valid_path() {
    [[ -n "$1" && "$1" != *[[:cntrl:]]* ]]
}

APP=''
CYCLES=10
STARTUP_TIMEOUT=15
SHUTDOWN_TIMEOUT=10
ARTIFACTS="${PWD}/soak-artifacts"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --app)
            require_value "$@"
            APP="$2"
            shift 2
            ;;
        --cycles)
            require_value "$@"
            CYCLES="$2"
            shift 2
            ;;
        --startup-timeout)
            require_value "$@"
            STARTUP_TIMEOUT="$2"
            shift 2
            ;;
        --shutdown-timeout)
            require_value "$@"
            SHUTDOWN_TIMEOUT="$2"
            shift 2
            ;;
        --artifacts)
            require_value "$@"
            ARTIFACTS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
    esac
done

[[ -n "${APP}" ]] || die '--app is required'
valid_path "${APP}" || die '--app must not contain control characters'
valid_path "${ARTIFACTS}" || die '--artifacts must not contain control characters'
[[ "${CYCLES}" =~ ^[1-9][0-9]*$ ]] || die '--cycles must be a positive integer'
[[ "${STARTUP_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
    die '--startup-timeout must be a positive integer'
[[ "${SHUTDOWN_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
    die '--shutdown-timeout must be a positive integer'

[[ "$(/usr/bin/uname -s)" == 'Darwin' ]] || die 'this soak test requires macOS'
for tool in /bin/cp /bin/kill /bin/mkdir /bin/ps /bin/rm /bin/sleep \
    /usr/bin/mktemp /usr/bin/pgrep /usr/bin/plutil; do
    [[ -x "${tool}" ]] || die "required macOS tool not found: ${tool}"
done

[[ -d "${APP}" ]] || die "application bundle not found: ${APP}"
PLIST="${APP}/Contents/Info.plist"
[[ -f "${PLIST}" ]] || die "Info.plist not found: ${PLIST}"
EXECUTABLE_NAME="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "${PLIST}" 2>/dev/null)" ||
    die 'Info.plist has no CFBundleExecutable'
[[ -n "${EXECUTABLE_NAME}" && "${EXECUTABLE_NAME}" != */* ]] ||
    die 'CFBundleExecutable must be a file name'
EXECUTABLE="${APP}/Contents/MacOS/${EXECUTABLE_NAME}"
[[ -f "${EXECUTABLE}" && -x "${EXECUTABLE}" ]] ||
    die "bundle executable is missing or not executable: ${EXECUTABLE}"
if [[ -e "${ARTIFACTS}" && ! -d "${ARTIFACTS}" ]]; then
    die "artifacts path is not a directory: ${ARTIFACTS}"
fi

RUN_DIR=''
CURRENT_CYCLE=0
CURRENT_CYCLE_DIR=''
CURRENT_PID_FILE=''
CURRENT_APP_PID=''
CURRENT_APP_IDENTITY=''
TRACKED_SHELL_PIDS=()
TRACKED_SHELL_IDENTITIES=()
DIRECT_SHELL_PIDS=()
RECORDED_SHELL_PIDS=()
PID_FILE_MALFORMED='false'
LAST_ARTIFACT=''

process_identity() {
    /bin/ps -ww -p "$1" -o lstart= -o command= 2>/dev/null
}

process_state() {
    /bin/ps -p "$1" -o state= 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

process_ppid() {
    /bin/ps -p "$1" -o ppid= 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

process_comm() {
    local comm

    comm="$(/bin/ps -p "$1" -o comm= 2>/dev/null)" || return 1
    comm="${comm//[[:space:]]/}"
    comm="${comm##*/}"
    comm="${comm#-}"
    printf '%s\n' "${comm}"
}

app_identity_matches() {
    local identity

    [[ -n "${CURRENT_APP_PID}" && -n "${CURRENT_APP_IDENTITY}" ]] || return 1
    identity="$(process_identity "${CURRENT_APP_PID}" || true)"
    [[ -n "${identity}" && "${identity}" == "${CURRENT_APP_IDENTITY}" ]]
}

shell_is_tracked() {
    local candidate="$1"
    local pid

    for pid in "${TRACKED_SHELL_PIDS[@]:-}"; do
        [[ "${pid}" == "${candidate}" ]] && return 0
    done
    return 1
}

track_shell() {
    local pid="$1"
    local identity

    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    shell_is_tracked "${pid}" && return 0
    [[ "$(process_comm "${pid}" || true)" == 'zsh' ]] || return 1
    identity="$(process_identity "${pid}" || true)"
    [[ -n "${identity}" ]] || return 1
    TRACKED_SHELL_PIDS+=("${pid}")
    TRACKED_SHELL_IDENTITIES+=("${identity}")
}

tracked_shell_identity_matches() {
    local index="$1"
    local identity

    identity="$(process_identity "${TRACKED_SHELL_PIDS[${index}]}" || true)"
    [[ -n "${identity}" && "${identity}" == "${TRACKED_SHELL_IDENTITIES[${index}]}" ]]
}

load_direct_shells() {
    local pid

    DIRECT_SHELL_PIDS=()
    [[ -n "${CURRENT_APP_PID}" ]] || return 0
    while IFS= read -r pid; do
        pid="${pid//[[:space:]]/}"
        [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || continue
        [[ "$(process_ppid "${pid}" || true)" == "${CURRENT_APP_PID}" ]] || continue
        [[ "$(process_comm "${pid}" || true)" == 'zsh' ]] || continue
        DIRECT_SHELL_PIDS+=("${pid}")
    done < <(/usr/bin/pgrep -P "${CURRENT_APP_PID}" -x zsh 2>/dev/null || true)
}

load_recorded_shells() {
    local pid extra seen
    local existing

    RECORDED_SHELL_PIDS=()
    PID_FILE_MALFORMED='false'
    [[ -f "${CURRENT_PID_FILE}" ]] || return 0
    while IFS=' ' read -r pid extra; do
        if [[ ! "${pid}" =~ ^[1-9][0-9]*$ || -n "${extra:-}" ]]; then
            PID_FILE_MALFORMED='true'
            continue
        fi
        seen='false'
        for existing in "${RECORDED_SHELL_PIDS[@]:-}"; do
            [[ "${existing}" == "${pid}" ]] && seen='true'
        done
        if [[ "${seen}" == 'true' ]]; then
            PID_FILE_MALFORMED='true'
        else
            RECORDED_SHELL_PIDS+=("${pid}")
        fi
    done < "${CURRENT_PID_FILE}"
}

same_two_pids() {
    local pid found

    [[ "${#DIRECT_SHELL_PIDS[@]}" -eq 2 && "${#RECORDED_SHELL_PIDS[@]}" -eq 2 ]] ||
        return 1
    [[ "${DIRECT_SHELL_PIDS[0]}" != "${DIRECT_SHELL_PIDS[1]}" ]] || return 1
    for pid in "${DIRECT_SHELL_PIDS[@]}"; do
        found='false'
        [[ "${RECORDED_SHELL_PIDS[0]}" == "${pid}" ]] && found='true'
        [[ "${RECORDED_SHELL_PIDS[1]}" == "${pid}" ]] && found='true'
        [[ "${found}" == 'true' ]] || return 1
    done
}

refresh_owned_shells() {
    local pid

    load_recorded_shells
    for pid in "${RECORDED_SHELL_PIDS[@]:-}"; do
        if app_identity_matches && [[ "$(process_ppid "${pid}" || true)" == "${CURRENT_APP_PID}" ]]; then
            track_shell "${pid}" || true
        fi
    done
    if app_identity_matches; then
        load_direct_shells
        for pid in "${DIRECT_SHELL_PIDS[@]:-}"; do
            track_shell "${pid}" || true
        done
    fi
}

cleanup_owned_processes() {
    local deadline index pid

    refresh_owned_shells || true
    if app_identity_matches; then
        /bin/kill -TERM "${CURRENT_APP_PID}" 2>/dev/null || true
        deadline=$((SECONDS + 2))
        while app_identity_matches && [[ "${SECONDS}" -lt "${deadline}" ]]; do
            /bin/sleep 0.1
        done
        if app_identity_matches; then
            /bin/kill -KILL "${CURRENT_APP_PID}" 2>/dev/null || true
        fi
    fi
    if [[ -n "${CURRENT_APP_PID}" ]]; then
        wait "${CURRENT_APP_PID}" 2>/dev/null || true
    fi

    deadline=$((SECONDS + 1))
    while [[ "${SECONDS}" -lt "${deadline}" ]]; do
        local_any='false'
        for ((index = 0; index < ${#TRACKED_SHELL_PIDS[@]}; index++)); do
            tracked_shell_identity_matches "${index}" && local_any='true'
        done
        [[ "${local_any}" == 'false' ]] && break
        /bin/sleep 0.1
    done
    for ((index = 0; index < ${#TRACKED_SHELL_PIDS[@]}; index++)); do
        if tracked_shell_identity_matches "${index}"; then
            pid="${TRACKED_SHELL_PIDS[${index}]}"
            /bin/kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    /bin/sleep 0.2
    for ((index = 0; index < ${#TRACKED_SHELL_PIDS[@]}; index++)); do
        if tracked_shell_identity_matches "${index}"; then
            pid="${TRACKED_SHELL_PIDS[${index}]}"
            /bin/kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
    CURRENT_APP_PID=''
    CURRENT_APP_IDENTITY=''
}

collect_diagnostics() {
    local reason="$1"
    local failure_dir

    /bin/mkdir -p -- "${ARTIFACTS}" || return 1
    failure_dir="$(/usr/bin/mktemp -d "${ARTIFACTS%/}/cycle-${CURRENT_CYCLE}-failure.XXXXXX")" ||
        return 1
    {
        printf 'cycle=%s\n' "${CURRENT_CYCLE}"
        printf 'reason=%s\n' "${reason}"
        printf 'app=%s\n' "${APP}"
        printf 'executable=%s\n' "${EXECUTABLE}"
        printf 'app_pid=%s\n' "${CURRENT_APP_PID}"
        printf 'tracked_shell_pids='
        printf '%s ' "${TRACKED_SHELL_PIDS[@]:-}"
        printf '\n'
    } > "${CURRENT_CYCLE_DIR}/failure.txt"
    /bin/ps -axo pid,ppid,pgid,sess,state,lstart,command \
        > "${CURRENT_CYCLE_DIR}/processes.txt" 2>&1 || true
    /bin/cp -R -- "${CURRENT_CYCLE_DIR}/." "${failure_dir}/" || return 1
    LAST_ARTIFACT="${failure_dir}"
}

on_exit() {
    cleanup_owned_processes || true
    if [[ -n "${RUN_DIR}" && -d "${RUN_DIR}" ]]; then
        /bin/rm -rf -- "${RUN_DIR}"
    fi
}

on_signal() {
    local signal="$1"
    local status="$2"

    if [[ -n "${CURRENT_CYCLE_DIR}" && -d "${CURRENT_CYCLE_DIR}" ]]; then
        collect_diagnostics "interrupted by ${signal}" || true
    fi
    exit "${status}"
}

fail_cycle() {
    local reason="$1"

    refresh_owned_shells || true
    if ! collect_diagnostics "${reason}"; then
        printf 'error: cycle %s: %s (diagnostic collection failed)\n' \
            "${CURRENT_CYCLE}" "${reason}" >&2
    else
        printf 'error: cycle %s: %s\n' "${CURRENT_CYCLE}" "${reason}" >&2
        printf 'diagnostics: %s\n' "${LAST_ARTIFACT}" >&2
    fi
    cleanup_owned_processes
    exit 1
}

trap on_exit EXIT
trap 'on_signal HUP 129' HUP
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

RUN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/soak-macos-app.XXXXXX")" ||
    die 'could not create temporary run directory'

printf 'soak: app=%s cycles=%s startup=%ss shutdown=%ss\n' \
    "${APP}" "${CYCLES}" "${STARTUP_TIMEOUT}" "${SHUTDOWN_TIMEOUT}"

for ((CURRENT_CYCLE = 1; CURRENT_CYCLE <= CYCLES; CURRENT_CYCLE++)); do
    CURRENT_CYCLE_DIR="${RUN_DIR}/cycle-${CURRENT_CYCLE}"
    HOME_DIR="${CURRENT_CYCLE_DIR}/home"
    CURRENT_PID_FILE="${CURRENT_CYCLE_DIR}/shell-pids.txt"
    CURRENT_APP_PID=''
    CURRENT_APP_IDENTITY=''
    TRACKED_SHELL_PIDS=()
    TRACKED_SHELL_IDENTITIES=()
    /bin/mkdir -p -- "${HOME_DIR}"
    cat > "${HOME_DIR}/.zshrc" <<'EOF'
# Controlled by soak-macos-app.sh; do not load user startup files.
unset HISTFILE
PROMPT='soak%# '
RPROMPT=''
print -r -- "$$" >> "${SOAK_SHELL_PID_FILE:?}"
EOF
    : > "${CURRENT_PID_FILE}"

    HOME="${HOME_DIR}" \
        ZDOTDIR="${HOME_DIR}" \
        SOAK_SHELL_PID_FILE="${CURRENT_PID_FILE}" \
        "${EXECUTABLE}" \
        > "${CURRENT_CYCLE_DIR}/app.stdout" \
        2> "${CURRENT_CYCLE_DIR}/app.stderr" &
    CURRENT_APP_PID=$!
    CURRENT_APP_IDENTITY="$(process_identity "${CURRENT_APP_PID}" || true)"
    [[ -n "${CURRENT_APP_IDENTITY}" ]] || fail_cycle 'app exited immediately after launch'

    startup_deadline=$((SECONDS + STARTUP_TIMEOUT))
    while true; do
        if ! app_identity_matches; then
            wait "${CURRENT_APP_PID}" 2>/dev/null || true
            fail_cycle 'app exited before both shells became ready'
        fi
        app_state="$(process_state "${CURRENT_APP_PID}" || true)"
        [[ "${app_state}" != Z* ]] || fail_cycle 'app became a zombie during startup'

        load_direct_shells
        load_recorded_shells
        [[ "${PID_FILE_MALFORMED}" == 'false' ]] ||
            fail_cycle 'controlled .zshrc produced malformed or duplicate shell PID records'
        [[ "${#DIRECT_SHELL_PIDS[@]}" -le 2 ]] ||
            fail_cycle "found more than two direct zsh children (${#DIRECT_SHELL_PIDS[@]})"
        [[ "${#RECORDED_SHELL_PIDS[@]}" -le 2 ]] ||
            fail_cycle "controlled .zshrc recorded more than two shell PIDs (${#RECORDED_SHELL_PIDS[@]})"

        if same_two_pids; then
            for shell_pid in "${DIRECT_SHELL_PIDS[@]}"; do
                shell_state="$(process_state "${shell_pid}" || true)"
                [[ -n "${shell_state}" && "${shell_state}" != Z* ]] ||
                    fail_cycle "direct shell ${shell_pid} is missing or a zombie"
                track_shell "${shell_pid}" ||
                    fail_cycle "could not establish identity for direct shell ${shell_pid}"
            done
            break
        fi
        [[ "${SECONDS}" -lt "${startup_deadline}" ]] ||
            fail_cycle "startup timed out with ${#DIRECT_SHELL_PIDS[@]} direct and ${#RECORDED_SHELL_PIDS[@]} recorded shells"
        /bin/sleep 0.1
    done

    app_pid_for_wait="${CURRENT_APP_PID}"
    /bin/kill -TERM "${CURRENT_APP_PID}" || fail_cycle 'could not terminate the exact app PID'
    shutdown_deadline=$((SECONDS + SHUTDOWN_TIMEOUT))
    shell_anomaly_counts=(0 0)
    shell_anomaly_reasons=('' '')
    while true; do
        app_present='false'
        if app_identity_matches; then
            app_present='true'
            app_state="$(process_state "${CURRENT_APP_PID}" || true)"
            if [[ "${app_state}" == Z* ]]; then
                wait "${app_pid_for_wait}" 2>/dev/null || true
                app_present='false'
            fi
        fi

        shells_present='false'
        for ((shell_index = 0; shell_index < ${#TRACKED_SHELL_PIDS[@]}; shell_index++)); do
            shell_pid="${TRACKED_SHELL_PIDS[${shell_index}]}"
            if tracked_shell_identity_matches "${shell_index}"; then
                shells_present='true'
                shell_state="$(process_state "${shell_pid}" || true)"
                shell_ppid="$(process_ppid "${shell_pid}" || true)"
                if [[ "${shell_state}" == Z* ]]; then
                    shell_anomaly_reasons[shell_index]="tracked shell ${shell_pid} remained a zombie during shutdown"
                    shell_anomaly_counts[shell_index]=$((shell_anomaly_counts[shell_index] + 1))
                elif [[ "${shell_ppid}" != "${CURRENT_APP_PID}" ]]; then
                    shell_anomaly_reasons[shell_index]="tracked shell ${shell_pid} remained an orphan (ppid ${shell_ppid:-unknown})"
                    shell_anomaly_counts[shell_index]=$((shell_anomaly_counts[shell_index] + 1))
                else
                    shell_anomaly_reasons[shell_index]=''
                    shell_anomaly_counts[shell_index]=0
                fi
                # A process can be observed briefly between exit and reap. Fail
                # only when a zombie/orphan persists across several polls.
                [[ "${shell_anomaly_counts[${shell_index}]}" -lt 5 ]] ||
                    fail_cycle "${shell_anomaly_reasons[${shell_index}]}"
            fi
        done

        if [[ "${app_present}" == 'false' && "${shells_present}" == 'false' ]]; then
            wait "${app_pid_for_wait}" 2>/dev/null || true
            break
        fi
        [[ "${SECONDS}" -lt "${shutdown_deadline}" ]] ||
            fail_cycle 'shutdown timed out before the app and tracked shells disappeared'
        /bin/sleep 0.1
    done

    [[ -z "$(process_identity "${app_pid_for_wait}" || true)" ]] ||
        fail_cycle 'app PID still exists after shutdown'
    for ((shell_index = 0; shell_index < ${#TRACKED_SHELL_PIDS[@]}; shell_index++)); do
        tracked_shell_identity_matches "${shell_index}" &&
            fail_cycle "tracked shell ${TRACKED_SHELL_PIDS[${shell_index}]} still exists after shutdown"
    done
    printf 'cycle %s/%s: ok (app pid %s; shells %s, %s)\n' \
        "${CURRENT_CYCLE}" "${CYCLES}" "${app_pid_for_wait}" \
        "${TRACKED_SHELL_PIDS[0]}" "${TRACKED_SHELL_PIDS[1]}"
    CURRENT_APP_PID=''
    CURRENT_APP_IDENTITY=''
done

printf 'soak passed: %s/%s cycles\n' "${CYCLES}" "${CYCLES}"

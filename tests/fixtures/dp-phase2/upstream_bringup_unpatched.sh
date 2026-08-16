#!/bin/bash
#
# Synthetic unpatched ACPS bringup fixture for Phase 2 patch-generation tests.
# Intentionally lacks project-owned worker password CLI handling.
# Production never ships this file; Download and Prepare patches a real ACPS
# upstream using the same unique anchors.
#
set -euo pipefail

###############################################################################
# USAGE EXAMPLES
###############################################################################
#
#   # Step 3d: Bringup DA/DL master + orchestrate workers automatically
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 \
#       --worker-ips 10.0.0.2,10.0.0.3 --worker-key /path/to/worker-ssh-key
#
# ============================================================================
# WORKFLOW: DA/DL Cluster with Workers
# ============================================================================
#
#   6. On master:
#        sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 \
#            --worker-ips <w1>,<w2> --worker-key /path/to/key
#
# ============================================================================
# ARGUMENTS
# ============================================================================
#
#   --version <ver>           Required (bringup). DP version, e.g., 6.5.0
#   --skip-download           Use already-staged tarballs (skip download)
#   --worker-ips <ip1,ip2>    Comma-separated worker IPs for master to orchestrate
#   --worker-key <path>       (deprecated) Workers use sshpass (aella/aelladata)
#   --role <role>             Override auto-detect: AIO|DR-master|DL-master|DR-worker|DL-worker
#
###############################################################################
# GLOBALS
###############################################################################
VERSION=""
WORKER_IPS=""
ROLE=""
DRY_RUN=false
SKIP_DOWNLOAD=false
WORKER_MODE=false
PRE_UPGRADE_CLEANUP=false
AUTO_OS_UPGRADE=false
RECLAIM_OVERLAY2_ONLY=false

LOG_FILE="${LOG_FILE:-/var/log/aella/aella_py3_bringup.log}"
DA_CONF="/opt/aelladata/work/da_conf.yml"
STAGING_DIR="/opt/aelladata/aelladeb_py3"
AELLADEB_DIR="/opt/aelladata/aelladeb"
SCP_OPTS="-o StrictHostKeyChecking=no"
SSH_OPTS="-o StrictHostKeyChecking=no"
WORKER_SSH_KEY=""  # deprecated: workers use sshpass (aella/aelladata)
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0")"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "$*"; }
log_phase() { echo "PHASE: $*"; }
check_version_guard() { :; }

###############################################################################
# PHASE 0: ARGUMENT PARSING & PRE-FLIGHT
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                VERSION="$2"; shift 2 ;;
            --worker-ips)
                WORKER_IPS="$2"; shift 2 ;;
            --role)
                ROLE="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --skip-download)
                SKIP_DOWNLOAD=true; shift ;;
            --worker-mode)
                WORKER_MODE=true; shift ;;
            --worker-key)
                WORKER_SSH_KEY="$2"; shift 2 ;;
            --pre-upgrade-cleanup)
                PRE_UPGRADE_CLEANUP=true; shift ;;
            --auto-os-upgrade)
                AUTO_OS_UPGRADE=true; shift ;;
            --reclaim-overlay2)
                RECLAIM_OVERLAY2_ONLY=true; shift ;;
            --help|-h)
                echo "Usage: $SCRIPT_NAME --version <dp-version> [options]"
                echo ""
                echo "Required:"
                echo "  --version <ver>         DP version (e.g., 6.5.0) -- must be >= 6.5.0"
                echo ""
                echo "Optional:"
                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"
                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker)"
                echo "  --dry-run               Pre-flight checks only"
                echo "  --skip-download         Use already-staged tarballs"
                echo "  --worker-mode           Internal: worker node mode"
                echo "  --pre-upgrade-cleanup   Clean stale apt repos, add correct Ubuntu repos, verify"
                echo "                          apt update/upgrade work. Run BEFORE do-release-upgrade."
                echo "  --auto-os-upgrade       Automated OS upgrade chain (16.04->24.04). Installs a"
                echo "                          systemd service that runs cleanup + do-release-upgrade"
                echo "                          on each boot until 24.04 is reached. Fully unattended."
                echo "                          Safe to re-run any time: auto-detects whether to resume"
                echo "                          (preserving hop_count + start_version) or initialize"
                echo "                          fresh (when state is missing or corrupted)."
                echo ""
                echo "Recovery (stuck mid-chain at 18.04 / 20.04 / 22.04):"
                echo "  1. SSH back in (sshd recovers within 90 min when systemd kills the stuck hop)."
                echo "  2. Check log: tail -50 /var/log/aella/auto_os_upgrade.log"
                echo "  3. Check state: cat /opt/aelladata/os-upgrade/state"
                echo "  4. Re-run: sudo bash $SCRIPT_NAME --auto-os-upgrade   # resumes or auto-resets"
                echo "  5. If state shows BLOCKED, wait for upstream services to recover, then re-run."
                exit 0 ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done

    # --version not required for pre-upgrade cleanup, auto-os-upgrade, or the
    # standalone overlay2 reclaim (a version-independent cleanup).
    if [[ "$PRE_UPGRADE_CLEANUP" != "true" && "$AUTO_OS_UPGRADE" != "true" && "$RECLAIM_OVERLAY2_ONLY" != "true" ]]; then
        if [[ -z "$VERSION" ]]; then die "--version is required"; fi
        check_version_guard
    fi
}

###############################################################################
# PHASE 1: DOWNLOAD ARTIFACTS
###############################################################################
download_artifacts() {
    log_phase "Download Artifacts"
    log "download_artifacts placeholder"
}

###############################################################################
# PHASE 2: INSTALL PYTHON 3
###############################################################################

install_python3() {
    log_phase "Install Python 3"

    # Ubuntu 24.04 ships python3.12 -- no tarball needed
    if python3 --version &>/dev/null; then
        log "Python 3 already installed: $(python3 --version 2>&1)"
    else
        die "Python 3 not found on Ubuntu 24.04 -- system is broken"
    fi

    local apt_tarball="${STAGING_DIR}/py3-apt-packages.tar.gz"
    if [[ -f "$apt_tarball" ]]; then
        log "Installing Python 3 system apt packages from local tarball..."
        local apt_tmpdir="/tmp/py3-apt-debs-$$"
        mkdir -p "$apt_tmpdir"
        tar -xzf "$apt_tarball" -C "$apt_tmpdir" || log "WARNING: Failed to extract py3-apt-packages.tar.gz"
        if ls "$apt_tmpdir"/*.deb &>/dev/null; then
            dpkg -i --force-depends "$apt_tmpdir"/*.deb 2>&1 | tail -10 || \
                log "WARNING: some debs in py3-apt-packages.tar.gz failed (continuing)"
        fi
        rm -rf "$apt_tmpdir"
    fi

    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        log "  --skip-download: skipping apt-based pip3 install (no internet)"
    elif ! command -v pip3 &>/dev/null; then
        log "Installing pip3..."
        apt-get update -qq 2>&1 | tail -3 || log "WARNING: apt-get update had errors"
        apt-get install -f -y -qq 2>&1 | tail -3 || log "WARNING: apt --fix-broken install had errors"
        if apt-get install -y -qq python3-pip python3-wheel python3-setuptools 2>&1 | tail -3; then
            log "pip3 installed via apt"
        else
            log "WARNING: apt install python3-pip failed"
        fi
    fi

    python3 -c "import psutil" 2>/dev/null || log "WARNING: psutil still missing"
    python3 -c "import pymongo" 2>/dev/null || log "WARNING: pymongo still missing"
    python3 -c "import flask" 2>/dev/null || log "WARNING: flask still missing"
    log "Python 3 system packages installed"
}

reclaim_overlay2_on_workers() {
    [[ -z "$WORKER_IPS" ]] && return 0
    if ! command -v sshpass &>/dev/null; then
        log "AELDEV-71912: sshpass unavailable -- skipping worker overlay2 sweep"
        return 0
    fi
    local WORKER_USER="aella" WORKER_PASS="aelladata"
    local workers worker_ip dry_flag=""
    [[ "$DRY_RUN" == "true" ]] && dry_flag=" --dry-run"
    IFS=',' read -ra workers <<< "$WORKER_IPS"
    log "overlay2 reclaim placeholder ${#workers[@]} ${dry_flag}"
}

load_local_images() {
    [[ "$SKIP_DOWNLOAD" != "true" ]] && return 0
    log_phase "Load Local Image Tarballs (dark-site)"
    local loaded=0 tarball size k8s_log moby_log k8s_rc moby_rc
    shopt -s nullglob
    for tarball in "$STAGING_DIR"/images-*.tar "$STAGING_DIR"/images-*.tar.gz; do
        size=$(du -h "$tarball" | awk '{print $1}')
        log "Loading $tarball ($size) into containerd k8s.io + moby namespaces (serial)..."
        k8s_log=$(mktemp /tmp/load_local_k8s.XXXXXX.log)
        moby_log=$(mktemp /tmp/load_local_moby.XXXXXX.log)
        k8s_rc=0; moby_rc=0
        if [[ "$tarball" == *.gz ]]; then
            gunzip -c "$tarball" | ctr -n=k8s.io images import - >"$k8s_log" 2>&1 || k8s_rc=$?
            gunzip -c "$tarball" | ctr -n=moby images import --no-unpack - >"$moby_log" 2>&1 || moby_rc=$?
        else
            ctr -n=k8s.io images import "$tarball" >"$k8s_log" 2>&1 || k8s_rc=$?
            ctr -n=moby images import --no-unpack "$tarball" >"$moby_log" 2>&1 || moby_rc=$?
        fi
        tail -3 "$k8s_log"  | while read -r line; do log "    k8s.io: $line"; done
        tail -3 "$moby_log" | while read -r line; do log "    moby:   $line"; done
        loaded=$((loaded + 1))
    done
    shopt -u nullglob
    log "loaded=$loaded"
}

###############################################################################
# PHASE 13: ORCHESTRATE WORKERS
###############################################################################
orchestrate_workers() {
    log_phase "Orchestrate Worker Nodes"

    if [[ -z "$WORKER_IPS" ]]; then
        log "No worker IPs specified, skipping"
        return 0
    fi

    # Worker SSH via sshpass (standard on-prem DP auth: aella/aelladata)
    local WORKER_PASS="aelladata"
    local WORKER_USER="aella"
    if ! command -v sshpass &>/dev/null; then
        log "Installing sshpass (needed for worker SSH)..."
        apt-get install -y sshpass &>/dev/null || die "Failed to install sshpass"
    fi
    mkdir -p ~/.ssh 2>/dev/null || true

    worker_ssh() {
        local ip="$1"; shift
        sshpass -p "$WORKER_PASS" ssh $SSH_OPTS "${WORKER_USER}@${ip}" "$@"
    }
    worker_scp() {
        local src="$1" dst_ip="$2" dst_path="$3"
        sshpass -p "$WORKER_PASS" scp $SCP_OPTS "$src" "${WORKER_USER}@${dst_ip}:${dst_path}"
    }

    local master_ip
    master_ip=$(kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print $6}' | head -1 || true)
    log "Master IP: $master_ip"
    log "Worker auth: sshpass (${WORKER_USER})"

    IFS=',' read -ra workers <<< "$WORKER_IPS"

    for worker_ip in "${workers[@]}"; do
        worker_ip=$(echo "$worker_ip" | xargs)  # trim whitespace
        [[ -z "$worker_ip" ]] && continue
        log ""
        log "--- Deploying worker: $worker_ip ---"

        log "Testing SSH to $worker_ip..."
        if ! worker_ssh "$worker_ip" "echo ok" &>/dev/null; then
            log "WARNING: First SSH to $worker_ip failed, retrying in 5s..."
            sleep 5
            if ! worker_ssh "$worker_ip" "echo ok" &>/dev/null; then
                log "ERROR: Cannot SSH to worker $worker_ip -- skipping"
                continue
            fi
        fi

        log "Copying script to $worker_ip..."
        worker_scp "$SCRIPT_PATH" "$worker_ip" "/tmp/${SCRIPT_NAME}"

        log "Copying staged artifacts to $worker_ip..."
        for f in "${STAGING_DIR}"/*.deb; do
            [[ -f "$f" ]] || continue
            local _scp_err _fname
            _fname=$(basename "$f")
            _scp_err=$(worker_scp "$f" "$worker_ip" "${STAGING_DIR}/" 2>&1 >/dev/null) || \
                log "  WARNING: failed to scp $(basename "$f"): ${_scp_err}"
        done

        log "Copying UVP debs to $worker_ip..."
        for f in "${AELLADEB_DIR}"/*.deb; do
            [[ -f "$f" ]] || continue
            local _scp_err
            _scp_err=$(worker_scp "$f" "$worker_ip" "${AELLADEB_DIR}/" 2>&1 >/dev/null) || \
                log "  WARNING: failed to scp $(basename "$f"): ${_scp_err}"
        done

        local worker_role
        if [[ "$ROLE" == "DR-master" ]]; then
            worker_role="DR-worker"
        elif [[ "$ROLE" == "DL-master" ]]; then
            worker_role="DL-worker"
        else
            worker_role="DR-worker"  # default
        fi

        log "Running bringup on worker $worker_ip (role: $worker_role)..."
        worker_ssh "$worker_ip" \
            "sudo bash /tmp/${SCRIPT_NAME} --version $VERSION --role $worker_role --worker-mode --skip-download" 2>&1 | \
            while IFS= read -r line; do log "  [$worker_ip] $line"; done || {
            log "WARNING: Worker $worker_ip bringup had errors"
        }

        sleep 10
        local worker_hostname
        worker_hostname=$(worker_ssh "$worker_ip" "hostname" 2>/dev/null || echo "unknown")
        if kubectl get nodes 2>/dev/null | grep -qi "$worker_hostname"; then
            log "Worker $worker_ip ($worker_hostname) joined cluster successfully"
        else
            log "WARNING: Worker $worker_ip ($worker_hostname) not yet visible in 'kubectl get nodes'"
            log "  It may still be joining -- check with: kubectl get nodes"
        fi

        log "Worker $worker_ip deployment complete"
    done

    # Final cluster state
    log "Cluster state after worker deployment:"
    kubectl get nodes -o wide 2>/dev/null || true
}

###############################################################################
# WORKER K8S JOIN (worker mode only)
###############################################################################
join_k8s_cluster() {
    log_phase "Join K8s Cluster (Worker)"
    local master_ip username password token="" host_name
    master_ip="127.0.0.1"
    username="user"
    password="pass"
    host_name=$(hostname)

    if [[ -n "$username" && -n "$password" ]]; then
        local token_response
        token_response=$(curl -sk -u "${username}:${password}" \
            "https://${master_ip}:8003/api/1.0/master_token?host=${host_name}" 2>/dev/null)
        log "Token API response length: ${#token_response}"
        token="$token_response"
    fi

    if [[ -z "$token" || "$token" == *"error"* || "$token" == *"Error"* ]]; then
        log "WARNING: Could not get token from REST API"
        log "  Response: ${token_response:-empty}"
        log "  Ensure master is fully up and aella_cluster_manager is running."
        die "Cannot get join token from master"
    fi
}

main() {
    parse_args "$@"
    download_artifacts
    install_python3
    load_local_images
    validate_all || true

    # Phase 13: Orchestrate workers (master only, after self is fully up)
    if [[ "$WORKER_MODE" != "true" && -n "$WORKER_IPS" ]]; then
        orchestrate_workers
    fi

    echo "========================================================================"
    echo "  Bringup complete: $(date)"
    echo "========================================================================"
    {
        echo "  Bringup complete: $(date)"
    } >> "$LOG_FILE" 2>/dev/null || true
}

validate_all() { return 0; }

detach_guard() {
    case " $* " in
        *" --worker-mode "*|*" --pre-upgrade-cleanup "*|*" --auto-os-upgrade "*) return 0 ;;
        *" --reclaim-overlay2 "*) return 0 ;;
        *" --dry-run "*|*" --help "*|*" -h "*) return 0 ;;
    esac
    [[ -n "${BRINGUP_DETACHED:-}" ]] && return 0
    command -v setsid >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "AELDEV-71573: detaching bringup so it survives SSH/console disconnect."
    echo "  Monitor:    tail -f $LOG_FILE"
    BRINGUP_DETACHED=1 setsid bash "$0" "$@" </dev/null >/dev/null 2>>"$LOG_FILE" &
    exit 0
}

detach_guard "$@"

main "$@"

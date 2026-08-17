###############################################################################
# PHASE 2 COMPATIBILITY: Ubuntu prerequisites + cluster readiness gates
###############################################################################
PHASE2_PREREQ_ARTIFACT_NAME="${PHASE2_PREREQ_ARTIFACT_NAME:-phase2-ubuntu-prerequisites.tar.gz}"
PHASE2_CRITICAL_PYTHON_IMPORTS="${PHASE2_CRITICAL_PYTHON_IMPORTS:-click flask werkzeug OpenSSL gevent kazoo pyinotify}"
MASTER_TOKEN_API_PORT="${MASTER_TOKEN_API_PORT:-8003}"
MASTER_TOKEN_API_WAIT_SECONDS="${MASTER_TOKEN_API_WAIT_SECONDS:-180}"
CLUSTER_JOIN_WAIT_SECONDS="${CLUSTER_JOIN_WAIT_SECONDS:-300}"

phase2_prereq_lib_paths() {
    printf '%s\n' \
        "${STAGING_DIR}/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/home/aella/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/opt/aelladata/os-upgrade/offline/phase2-bringup/lib/dp-phase2-ubuntu-prerequisites.sh"
}

source_phase2_prereq_lib() {
    local p
    while IFS= read -r p; do
        if [[ -f "$p" ]]; then
            # shellcheck source=/dev/null
            source "$p"
            return 0
        fi
    done < <(phase2_prereq_lib_paths)
    return 1
}

count_expected_cluster_nodes() {
    local ips="$1"
    local n=0 ip
    [[ -n "$ips" ]] || { printf '0\n'; return 0; }
    IFS=',' read -ra _exp_workers <<< "$ips"
    for ip in "${_exp_workers[@]}"; do
        ip="${ip//[[:space:]]/}"
        [[ -n "$ip" ]] && n=$((n + 1))
    done
    if [[ "$n" -eq 0 ]]; then
        printf '0\n'
    else
        printf '%s\n' $((n + 1))
    fi
}

validate_apt_dependency_graph() {
    local stage="${1:-unspecified}"
    if source_phase2_prereq_lib && declare -F dp2_validate_apt_dependency_graph >/dev/null 2>&1; then
        dp2_validate_apt_dependency_graph "$stage"
        return $?
    fi
    local audit="" rc=0
    audit="$(dpkg --audit 2>&1 || true)"
    if [[ -n "${audit// }" ]]; then
        log "WARNING: DPKG_AUDIT=DIRTY stage=${stage}"
    else
        log "DPKG_AUDIT=CLEAN stage=${stage} (not sufficient)"
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        log "ERROR: APT_DEPENDENCY_CHECK=FAIL stage=${stage} reason=apt-get_missing"
        return 1
    fi
    local prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    apt-get -o Debug::NoLocking=true check >/dev/null 2>&1
    rc=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    if [[ "$rc" -ne 0 ]]; then
        log "ERROR: APT_DEPENDENCY_CHECK=FAIL stage=${stage} rc=${rc}"
        return "$rc"
    fi
    log "APT_DEPENDENCY_CHECK=PASS stage=${stage}"
    return 0
}

validate_critical_python_runtime() {
    local missing=() mod
    if source_phase2_prereq_lib && declare -F dp2_validate_critical_python_runtime >/dev/null 2>&1; then
        dp2_validate_critical_python_runtime
        return $?
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log "ERROR: CRITICAL_PYTHON_RUNTIME=FAIL reason=python3_missing"
        return 1
    fi
    for mod in $PHASE2_CRITICAL_PYTHON_IMPORTS; do
        if ! python3 -c "import ${mod}" >/dev/null 2>&1; then
            missing+=("$mod")
            log "ERROR: CRITICAL_PYTHON_IMPORT=FAIL module=${mod}"
        else
            log "CRITICAL_PYTHON_IMPORT=PASS module=${mod}"
        fi
    done
    if ! python3 -c "import asyncore" >/dev/null 2>&1; then
        missing+=("asyncore")
        log "ERROR: CRITICAL_PYTHON_IMPORT=FAIL module=asyncore"
    else
        log "CRITICAL_PYTHON_IMPORT=PASS module=asyncore"
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: CRITICAL_PYTHON_RUNTIME=FAIL missing=${missing[*]}"
        return 1
    fi
    log "CRITICAL_PYTHON_RUNTIME=PASS"
    return 0
}

install_phase2_ubuntu_prerequisites() {
    if source_phase2_prereq_lib && declare -F dp2_install_phase2_ubuntu_prerequisites >/dev/null 2>&1; then
        dp2_install_phase2_ubuntu_prerequisites
        return $?
    fi
    log "ERROR: PHASE2_PREREQ_INSTALL=FAIL reason=prereq_lib_missing"
    return 1
}

# Exact prerequisite contract filenames. Do not use extension globs as the
# protocol: workers must receive these files intentionally.
phase2_prereq_contract_state_name() { printf '%s\n' "phase2-ubuntu-prerequisites.state"; }
phase2_prereq_contract_artifact_name() { printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz"; }
phase2_prereq_contract_sidecar_name() { printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz.sha256"; }
phase2_prereq_contract_manifest_name() { printf '%s\n' "phase2-ubuntu-prerequisites.manifest.json"; }
phase2_prereq_contract_lib_name() { printf '%s\n' "dp-phase2-ubuntu-prerequisites.sh"; }

phase2_prereq_lib_source_path() {
    local p
    for p in \
        "${STAGING_DIR}/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/home/aella/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/opt/aelladata/os-upgrade/offline/phase2-bringup/lib/dp-phase2-ubuntu-prerequisites.sh"
    do
        if [[ -f "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# Remove only the current-generation prerequisite contract files. Never
# glob-delete unrelated staged artifacts.
clean_phase2_prereq_contract_files() {
    local dir="${1:-${STAGING_DIR:-/opt/aelladata/aelladeb_py3}}"
    rm -f \
        "${dir}/phase2-ubuntu-prerequisites.state" \
        "${dir}/phase2-ubuntu-prerequisites.tar.gz" \
        "${dir}/phase2-ubuntu-prerequisites.tar.gz.sha256" \
        "${dir}/phase2-ubuntu-prerequisites.manifest.json"
}

# Copy the current prerequisite contract to one worker. MUST run after the
# generic staging glob copy so a leftover REQUIRED=YES tarball cannot remain
# as the worker's current artifact when the new state is REQUIRED=NO.
copy_phase2_prereq_contract_to_worker() {
    local worker_ip="$1"
    local staging="${STAGING_DIR:-/opt/aelladata/aelladeb_py3}"
    local state="${staging}/phase2-ubuntu-prerequisites.state"
    local artifact="${staging}/phase2-ubuntu-prerequisites.tar.gz"
    local sidecar="${artifact}.sha256"
    local manifest="${staging}/phase2-ubuntu-prerequisites.manifest.json"
    local lib_src="" required=""
    local remote_clean remote_mkdir

    if ! declare -F worker_ssh >/dev/null 2>&1 || ! declare -F worker_scp >/dev/null 2>&1; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=ssh_helpers_missing"
        return 1
    fi

    remote_clean="sudo rm -f \
'${staging}/phase2-ubuntu-prerequisites.state' \
'${staging}/phase2-ubuntu-prerequisites.tar.gz' \
'${staging}/phase2-ubuntu-prerequisites.tar.gz.sha256' \
'${staging}/phase2-ubuntu-prerequisites.manifest.json' \
'${staging}/lib/dp-phase2-ubuntu-prerequisites.sh'"
    remote_mkdir="sudo mkdir -p '${staging}' '${staging}/lib' && sudo chmod 777 '${staging}' '${staging}/lib'"
    if ! worker_ssh "$worker_ip" "$remote_mkdir"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=worker_mkdir"
        return 1
    fi
    if ! worker_ssh "$worker_ip" "$remote_clean"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=worker_clean"
        return 1
    fi

    if [[ ! -f "$state" ]]; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=state_missing"
        return 1
    fi
    if ! worker_scp "$state" "$worker_ip" "${staging}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=state_copy"
        return 1
    fi

    if ! lib_src="$(phase2_prereq_lib_source_path)"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=lib_missing"
        return 1
    fi
    if ! worker_scp "$lib_src" "$worker_ip" "${staging}/lib/dp-phase2-ubuntu-prerequisites.sh"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=lib_copy"
        return 1
    fi

    required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
    if [[ "$required" == "NO" ]]; then
        log "PHASE2_PREREQ_WORKER_COPY=NOT_REQUIRED"
        return 0
    fi
    if [[ "$required" != "YES" ]]; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=required_invalid"
        return 1
    fi
    if [[ ! -f "$artifact" || ! -f "$sidecar" || ! -f "$manifest" ]]; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=required_file_missing"
        return 1
    fi
    if ! worker_scp "$artifact" "$worker_ip" "${staging}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=artifact_copy"
        return 1
    fi
    if ! worker_scp "$sidecar" "$worker_ip" "${staging}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=sidecar_copy"
        return 1
    fi
    if ! worker_scp "$manifest" "$worker_ip" "${staging}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=manifest_copy"
        return 1
    fi
    log "PHASE2_PREREQ_WORKER_COPY=PASS"
    return 0
}

wait_for_master_token_api() {
    local timeout_s="${1:-$MASTER_TOKEN_API_WAIT_SECONDS}"
    local port="${MASTER_TOKEN_API_PORT}"
    local started now elapsed
    local loopback_code=000 master_ip_code=000
    local loopback_ready=0 master_ip_ready=0
    local cluster_mode=0
    if [[ -n "${WORKER_IPS:-}" ]]; then
        cluster_mode=1
    fi
    started="$(date +%s)"
    log "Waiting for master token API on TCP/${port} (timeout=${timeout_s}s cluster=${cluster_mode})"
    while true; do
        loopback_code="$(curl -sk --connect-timeout 5 --max-time 10 \
            -o /dev/null -w '%{http_code}' "https://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
        if [[ "$loopback_code" =~ ^(200|401|403|404)$ ]]; then
            loopback_ready=1
        else
            loopback_ready=0
        fi
        master_ip_ready=0
        master_ip_code=000
        if [[ -n "${MASTER_IP:-}" ]]; then
            master_ip_code="$(curl -sk --connect-timeout 5 --max-time 10 \
                -o /dev/null -w '%{http_code}' "https://${MASTER_IP}:${port}/" 2>/dev/null || echo 000)"
            if [[ "$master_ip_code" =~ ^(200|401|403|404)$ ]]; then
                master_ip_ready=1
            fi
        fi
        if [[ "$cluster_mode" -eq 1 ]]; then
            if [[ -z "${MASTER_IP:-}" ]]; then
                log "MASTER_IP_8003_READY=NO reason=master_ip_unset"
                log "MASTER_TOKEN_API_READY=NO"
                log "BRINGUP_RESULT=FAIL"
                return 1
            fi
            if [[ "$master_ip_ready" -eq 1 ]]; then
                if [[ "$loopback_ready" -eq 1 ]]; then
                    log "LOOPBACK_8003_READY=YES"
                else
                    log "LOOPBACK_8003_READY=NO http=${loopback_code}"
                fi
                log "MASTER_IP_8003_READY=YES port=${port} http=${master_ip_code}"
                log "MASTER_TOKEN_API_READY=YES port=${port} http=${master_ip_code}"
                return 0
            fi
        else
            if [[ "$loopback_ready" -eq 1 ]]; then
                log "LOOPBACK_8003_READY=YES port=${port} http=${loopback_code}"
                if [[ -n "${MASTER_IP:-}" ]]; then
                    if [[ "$master_ip_ready" -eq 1 ]]; then
                        log "MASTER_IP_8003_READY=YES"
                    else
                        log "MASTER_IP_8003_READY=NO http=${master_ip_code}"
                    fi
                else
                    log "MASTER_IP_8003_READY=NOT_REQUIRED"
                fi
                log "MASTER_TOKEN_API_READY=YES port=${port} http=${loopback_code}"
                return 0
            fi
        fi
        now="$(date +%s)"
        elapsed=$((now - started))
        if [[ "$elapsed" -ge "$timeout_s" ]]; then
            if [[ "$loopback_ready" -eq 1 ]]; then
                log "LOOPBACK_8003_READY=YES http=${loopback_code}"
            else
                log "LOOPBACK_8003_READY=NO http=${loopback_code}"
            fi
            if [[ "$cluster_mode" -eq 1 || -n "${MASTER_IP:-}" ]]; then
                log "MASTER_IP_8003_READY=NO http=${master_ip_code}"
            else
                log "MASTER_IP_8003_READY=NOT_REQUIRED"
            fi
            log "MASTER_TOKEN_API_READY=NO port=${port} last_http=${master_ip_code:-$loopback_code} waited=${elapsed}s"
            log "BRINGUP_RESULT=FAIL"
            return 1
        fi
        sleep 5
    done
}

kubectl_ready_node_count() {
    kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready($|,)/ {c++} END {print c+0}'
}

validate_expected_cluster_nodes() {
    local expected timeout_s started now elapsed ready
    expected="$(count_expected_cluster_nodes "${WORKER_IPS:-}")"
    if [[ "${expected:-0}" -le 1 ]]; then
        log "CLUSTER_JOIN_STATE skipped (no worker IPs; single-node/AIO)"
        return 0
    fi
    timeout_s="${1:-$CLUSTER_JOIN_WAIT_SECONDS}"
    started="$(date +%s)"
    while true; do
        ready="$(kubectl_ready_node_count)"
        log "CLUSTER_JOIN_STATE ready=${ready} expected=${expected}"
        if [[ "${ready:-0}" -eq "$expected" ]]; then
            return 0
        fi
        now="$(date +%s)"
        elapsed=$((now - started))
        if [[ "$elapsed" -ge "$timeout_s" ]]; then
            log "ERROR: CLUSTER_JOIN_STATE ready=${ready} expected=${expected} waited=${elapsed}s"
            log "BRINGUP_RESULT=FAIL"
            return 1
        fi
        sleep 5
    done
}


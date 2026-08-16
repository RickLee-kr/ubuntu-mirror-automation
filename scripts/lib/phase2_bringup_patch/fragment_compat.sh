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
    local artifact="${STAGING_DIR}/${PHASE2_PREREQ_ARTIFACT_NAME}"
    if [[ ! -f "$artifact" ]]; then
        validate_apt_dependency_graph prerequisites || return 1
        log "PHASE2_PREREQ_INSTALL=SKIP reason=artifact_absent"
        return 0
    fi
    local extract deb pkg rc=0
    extract="$(mktemp -d /tmp/phase2-prereq-inst.XXXXXX)"
    tar -xzf "$artifact" -C "$extract" || { rm -rf "$extract"; return 1; }
    shopt -s nullglob
    for deb in "${extract}/debs/"*.deb; do
        pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
        if [[ -z "$pkg" ]]; then
            rm -rf "$extract"
            log "ERROR: PHASE2_PREREQ_INSTALL=FAIL reason=deb_control_missing"
            return 1
        fi
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
            log "PHASE2_PREREQ_ALREADY_INSTALLED package=${pkg}"
            continue
        fi
        if ! dpkg -i "$deb"; then
            rc=$?
            rm -rf "$extract"
            log "ERROR: PHASE2_PREREQ_DPKG=FAIL package=${pkg} rc=${rc}"
            return "$rc"
        fi
        log "PHASE2_PREREQ_DPKG=PASS package=${pkg}"
    done
    shopt -u nullglob
    rm -rf "$extract"
    validate_apt_dependency_graph prerequisites || return 1
    log "PHASE2_PREREQ_INSTALL=PASS"
    return 0
}

wait_for_master_token_api() {
    local timeout_s="${1:-$MASTER_TOKEN_API_WAIT_SECONDS}"
    local port="${MASTER_TOKEN_API_PORT}"
    local started now elapsed code=000
    local targets=()
    targets+=("https://127.0.0.1:${port}/")
    if [[ -n "${MASTER_IP:-}" ]]; then
        targets+=("https://${MASTER_IP}:${port}/")
    fi
    started="$(date +%s)"
    log "Waiting for master token API on TCP/${port} (timeout=${timeout_s}s)"
    while true; do
        local url
        for url in "${targets[@]}"; do
            code="$(curl -sk --connect-timeout 5 --max-time 10 \
                -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
            # 200/401/403/404 prove the HTTPS listener is up. Do not log bodies.
            if [[ "$code" =~ ^(200|401|403|404)$ ]]; then
                log "MASTER_TOKEN_API_READY=YES port=${port} http=${code}"
                return 0
            fi
        done
        now="$(date +%s)"
        elapsed=$((now - started))
        if [[ "$elapsed" -ge "$timeout_s" ]]; then
            log "MASTER_TOKEN_API_READY=NO port=${port} last_http=${code} waited=${elapsed}s"
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


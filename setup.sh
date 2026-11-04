#!/bin/bash
# Dynamic WAN setup — multi-uplink (parameters.txt), demo.sh-compatible core path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PARAMS_FILE="$SCRIPT_DIR/parameters.txt"
STATE_FILE="/etc/dynamicwan_configured_interfaces.conf"
NAT_SCRIPT="/usr/local/bin/setup-nat-dynamicwan.sh"
NAT_SERVICE="setup-nat-dynamicwan.service"
# Dedicated netplan drop-in — do NOT edit 01-/50-/90-NM-*.yaml (all are merged by netplan)
NETPLAN_FILE="/etc/netplan/99-dynamicwan-uplinks.yaml"
NETPLAN_RENDERER="NetworkManager"

declare -a ACTIVE_INTERFACES=()
declare -a ACTIVE_LAN_IPS=()
declare -a ACTIVE_LAN_SUBNETS=()
declare -a ACTIVE_LAN_NET_ADDRS=()
NUM_ACTIVE_UPLINKS=0
INTERNET_IFACE=""

FAIL_REASON=""
CURRENT_STEP="init"
ROLLBACK_ENABLED=true
NETPLAN_DONE=false
NAT_DONE=false
CONTAINERS_STARTED=false
SYSCTL_MODIFIED=false
PREV_IP_FORWARD=""

die() {
    FAIL_REASON="$*"
    echo "" >&2
    echo "ERROR: $FAIL_REASON" >&2
    echo "Failed at step: $CURRENT_STEP" >&2
    exit 1
}

set_step() {
    CURRENT_STEP="$1"
    echo ""
    echo "==> $CURRENT_STEP"
}

rollback_changes() {
    local ec=$?
    # Successful exit or rollback already disabled
    if [ "$ROLLBACK_ENABLED" != true ] || [ "$ec" -eq 0 ]; then
        return 0
    fi

    trap - ERR EXIT

    echo ""
    echo "========================================"
    echo "SETUP FAILED — ROLLING BACK"
    echo "========================================"
    if [ -n "$FAIL_REASON" ]; then
        echo "Reason: $FAIL_REASON"
    else
        echo "Reason: command failed during step '$CURRENT_STEP' (exit $ec)"
    fi
    echo "Step:   $CURRENT_STEP"
    echo "========================================"

    # Containers
    if [ "$CONTAINERS_STARTED" = true ]; then
        echo "→ Removing containers..."
        for c in frr_dyn dhcpd_dyn radiusd_dyn; do
            sudo docker stop "$c" >/dev/null 2>&1 || true
            sudo docker rm "$c" >/dev/null 2>&1 || true
        done
    fi

    # NAT / forwarding
    if [ "$NAT_DONE" = true ]; then
        echo "→ Reverting NAT / forwarding..."
        sudo systemctl stop "$NAT_SERVICE" >/dev/null 2>&1 || true
        sudo systemctl disable "$NAT_SERVICE" >/dev/null 2>&1 || true
        sudo rm -f "/etc/systemd/system/${NAT_SERVICE}"
        sudo rm -f "$NAT_SCRIPT"
        sudo systemctl daemon-reload >/dev/null 2>&1 || true
        _remove_nat_rules_from_state || true
        if [ "$SYSCTL_MODIFIED" = true ] && [ -n "$PREV_IP_FORWARD" ]; then
            echo "$PREV_IP_FORWARD" | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null || true
            sudo sed -i '/^net\.ipv4\.ip_forward=1$/d' /etc/sysctl.conf 2>/dev/null || true
        fi
    fi

    # Netplan + runtime IPs (including ip addr add fallback)
    if [ "$NETPLAN_DONE" = true ] && [ "$NUM_ACTIVE_UPLINKS" -gt 0 ]; then
        echo "→ Reverting LAN IPs / netplan..."
        local _i _iface _lan_ip
        for ((_i=0; _i<NUM_ACTIVE_UPLINKS; _i++)); do
            _iface="${ACTIVE_INTERFACES[_i]}"
            _lan_ip="${ACTIVE_LAN_IPS[_i]}"
            if ip link show "$_iface" &>/dev/null && ip -4 addr show dev "$_iface" 2>/dev/null | grep -q "inet ${_lan_ip%%/*}/"; then
                sudo ip addr del "$_lan_ip" dev "$_iface" 2>/dev/null || true
            fi
        done
        # Our config lives only in the dedicated drop-in file
        sudo rm -f "$NETPLAN_FILE"
        sudo netplan apply >/dev/null 2>&1 || true
    fi

    sudo rm -f "$STATE_FILE" /tmp/dynamicwan_configured_interfaces.conf /tmp/dynamicwan_ip_addr_err
    echo "Rollback finished. System restored as far as possible."
    exit 1
}

trap rollback_changes ERR EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_netplan_remove_iface() {
    local iface="$1" netplan_file="$2"
    sudo python3 -c "
import yaml
with open('$netplan_file') as f:
    cfg = yaml.safe_load(f) or {}
eth = cfg.get('network', {}).get('ethernets', {})
if '$iface' in eth:
    del eth['$iface']
    with open('$netplan_file', 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
"
}

# iptables -t TABLE must come before -C/-A/-D
_iptables_del_nat() {
    if sudo iptables -t nat -C "$@" >/dev/null 2>&1; then
        sudo iptables -t nat -D "$@" || true
    fi
}

_iptables_del_filter() {
    if sudo iptables -C "$@" >/dev/null 2>&1; then
        sudo iptables -D "$@" || true
    fi
}

_remove_nat_rules_from_state() {
    local state="${1:-$STATE_FILE}"
    [ -f "$state" ] || return 0
    local inet=""
    inet=$(grep -E '^internet_interface=' "$state" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$inet" ] || return 0

    _iptables_del_nat POSTROUTING -o "$inet" -j MASQUERADE -m comment --comment "dynamicwan"
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        _iptables_del_filter FORWARD -i "$iface" -o "$inet" -j ACCEPT -m comment --comment "dynamicwan"
        _iptables_del_filter FORWARD -i "$inet" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "dynamicwan"
    done < <(grep -E '^interface=' "$state" 2>/dev/null | cut -d= -f2- || true)
}

iface_exists() {
    ip link show "$1" &>/dev/null
}

iface_is_up() {
    local state
    state=$(ip -o link show "$1" 2>/dev/null | awk '{
        for (i=1;i<=NF;i++) if ($i ~ /^state$/) { print $(i+1); exit }
    }')
    # Also treat LOWER_UP / operstate up
    local oper
    oper=$(cat "/sys/class/net/$1/operstate" 2>/dev/null || echo unknown)
    [[ "$state" == "UP" || "$oper" == "up" ]]
}

# ---------------------------------------------------------------------------
# 1) Parse parameters.txt (no eval)
# ---------------------------------------------------------------------------
parse_parameters() {
    set_step "Parse parameters.txt"

    [ -f "$PARAMS_FILE" ] || die "Parameters file not found: $PARAMS_FILE"

    local i iface lan_ip lan_subnet line key val
    declare -A P=()

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^uplink[1-4]_(interface|lan_ip|lan_subnet)= ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        val="${val#\"}"
        val="${val%\"}"
        # Reject broken unclosed quotes left in file
        if [[ "$line" =~ =\"[^\"]*$ ]] && [[ ! "$line" =~ =\"[^\"]*\"[[:space:]]*$ ]]; then
            die "Malformed line in parameters.txt (unclosed quote): $line"
        fi
        P["$key"]="$val"
    done < "$PARAMS_FILE"

    for i in 1 2 3 4; do
        iface="${P[uplink${i}_interface]:-}"
        lan_ip="${P[uplink${i}_lan_ip]:-}"
        lan_subnet="${P[uplink${i}_lan_subnet]:-}"

        if [ -z "$iface" ] && [ -z "$lan_ip" ] && [ -z "$lan_subnet" ]; then
            echo "Uplink $i: disabled"
            continue
        fi
        if [ -z "$iface" ] || [ -z "$lan_ip" ] || [ -z "$lan_subnet" ]; then
            die "Uplink $i incomplete — set interface, lan_ip, and lan_subnet (or leave all empty)"
        fi
        if [[ ! "$lan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            die "Uplink $i: invalid lan_ip '$lan_ip' (expected x.x.x.x/y)"
        fi
        if [[ ! "$lan_subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            die "Uplink $i: invalid lan_subnet '$lan_subnet' (expected x.x.x.x/y)"
        fi

        ACTIVE_INTERFACES+=("$iface")
        ACTIVE_LAN_IPS+=("$lan_ip")
        ACTIVE_LAN_SUBNETS+=("$lan_subnet")
        ACTIVE_LAN_NET_ADDRS+=("$(echo "$lan_subnet" | cut -d/ -f1)")
        echo "Uplink $i: $iface  $lan_ip  ($lan_subnet)"
    done

    NUM_ACTIVE_UPLINKS=${#ACTIVE_INTERFACES[@]}
    [ "$NUM_ACTIVE_UPLINKS" -gt 0 ] || die "No active uplinks in $PARAMS_FILE"
    echo "Active uplinks: $NUM_ACTIVE_UPLINKS"
}

# ---------------------------------------------------------------------------
# 2) Dependencies — install only if missing
# ---------------------------------------------------------------------------
need_apt_update=false

ensure_pkg() {
    local pkg="$1"
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        return 0
    fi
    echo "Installing package: $pkg"
    if [ "$need_apt_update" = true ]; then
        sudo apt-get update -qq
        need_apt_update=false
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" \
        || die "Failed to install package: $pkg"
}

ensure_command_pkg() {
    local cmd="$1" pkg="$2"
    if command -v "$cmd" &>/dev/null; then
        echo "OK: $cmd"
        return 0
    fi
    need_apt_update=true
    ensure_pkg "$pkg"
    command -v "$cmd" &>/dev/null || die "Command '$cmd' still missing after installing $pkg"
    echo "OK: $cmd (installed)"
}

ensure_docker() {
    if command -v docker &>/dev/null && sudo docker info &>/dev/null; then
        echo "OK: docker"
        return 0
    fi

    echo "Docker missing or not running — installing..."
    need_apt_update=true
    ensure_pkg ca-certificates
    ensure_pkg curl
    ensure_pkg docker.io
    sudo systemctl enable --now docker
    sleep 2
    sudo docker info &>/dev/null || die "Docker installed but daemon is not running"
    echo "OK: docker (installed)"
}

check_dependencies() {
    set_step "Check / install dependencies"
    sudo -n true 2>/dev/null || sudo -v || die "sudo privileges required"

    need_apt_update=true
    ensure_command_pkg python3 python3
    if ! python3 -c "import yaml" &>/dev/null; then
        ensure_pkg python3-yaml
        python3 -c "import yaml" &>/dev/null || die "PyYAML not available after install"
    else
        echo "OK: python3-yaml"
    fi
    ensure_command_pkg ip iproute2
    ensure_command_pkg iptables iptables
    ensure_command_pkg netplan netplan.io
    ensure_docker

    if [ ! -d /etc/netplan ]; then
        die "/etc/netplan does not exist — install/configure netplan first"
    fi

    # All *.yaml under /etc/netplan are merged (none is "the only active" file).
    # We never edit existing 01-/50-/90-NM files; we use a dedicated drop-in.
    detect_netplan_renderer
    echo "OK: netplan present (renderer: $NETPLAN_RENDERER)"
    echo "    Existing netplan files (all merged by netplan):"
    ls -1 /etc/netplan/*.yaml 2>/dev/null | sed 's/^/      /' || echo "      (none yet)"
    echo "    This script will write ONLY: $NETPLAN_FILE"
}

detect_netplan_renderer() {
    # Prefer explicit renderer from any existing yaml; default NetworkManager on desktop
    local r
    r=$(grep -hE '^\s*renderer:' /etc/netplan/*.yaml 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' || true)
    if [ -n "$r" ]; then
        NETPLAN_RENDERER="$r"
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NETPLAN_RENDERER="NetworkManager"
    else
        NETPLAN_RENDERER="networkd"
    fi
}

# ---------------------------------------------------------------------------
# 3) Internet uplink detection (eth or wifi)
# ---------------------------------------------------------------------------
detect_internet_iface() {
    local best="" best_metric=999999999 line iface metric

    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        metric=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="metric"){print $(i+1); exit}}')
        metric=${metric:-0}
        [ -n "$iface" ] || continue
        if [ "$metric" -lt "$best_metric" ]; then
            best_metric=$metric
            best=$iface
        fi
    done < <(ip -4 route show default 2>/dev/null || true)

    if [ -z "$best" ]; then
        best=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    fi

    echo "$best"
}

# Return space-separated IPv4 CIDRs currently on an interface (empty if none)
existing_ipv4_on_iface() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

prompt_existing_lan_ips() {
    local -a warn_ifaces=()
    local -a warn_existing=()
    local -a warn_planned=()
    local iface i existing

    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        iface="${ACTIVE_INTERFACES[i]}"
        existing=$(existing_ipv4_on_iface "$iface")
        [ -n "$existing" ] || continue
        warn_ifaces+=("$iface")
        warn_existing+=("$existing")
        warn_planned+=("${ACTIVE_LAN_IPS[i]}")
    done

    [ ${#warn_ifaces[@]} -gt 0 ] || return 0

    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  WARNING: One or more LAN interfaces already have IP addresses"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo "Setup is about to configure these interfaces for Dynamic WAN."
    echo "Existing addresses may be replaced or changed by netplan."
    echo ""
    for ((i=0; i<${#warn_ifaces[@]}; i++)); do
        echo "  Interface : ${warn_ifaces[i]}"
        echo "  Existing  : ${warn_existing[i]}"
        echo "  Planned   : ${warn_planned[i]}  (from parameters.txt)"
        echo ""
    done
    echo "If you continue, the planned address(es) above will be applied."
    echo "If these interfaces are used by something else, stop and pick different"
    echo "interfaces in parameters.txt."
    echo ""
    local ans
    read -r -p "An IP already exists on the LAN interface(s) above. Proceed anyway? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        ROLLBACK_ENABLED=false
        echo "Setup cancelled — no changes were made."
        exit 0
    fi
    echo "Continuing with setup as requested."
}

preflight_checks() {
    set_step "Preflight checks"

    local iface i
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        iface="${ACTIVE_INTERFACES[i]}"
        iface_exists "$iface" || die "LAN uplink interface '$iface' does not exist. Check: ip link show"
        # LAN may be down now — user can cable/bring it up later; do not fail
        if iface_is_up "$iface"; then
            echo "OK: LAN $iface exists (UP) — will use ${ACTIVE_LAN_IPS[i]}"
        else
            echo "OK: LAN $iface exists (currently DOWN) — will use ${ACTIVE_LAN_IPS[i]}"
            echo "    Interface can be brought up later; setup will continue."
        fi
        local existing
        existing=$(existing_ipv4_on_iface "$iface")
        if [ -n "$existing" ]; then
            echo "    Current IPv4 on $iface: $existing"
        else
            echo "    No IPv4 address currently configured on $iface"
        fi
    done

    prompt_existing_lan_ips

    INTERNET_IFACE=$(detect_internet_iface)
    [ -n "$INTERNET_IFACE" ] || die "No default route / internet uplink found (wired or Wi-Fi). Connect the server to the network and retry."

    iface_exists "$INTERNET_IFACE" || die "Detected internet interface '$INTERNET_IFACE' does not exist"
    if ! iface_is_up "$INTERNET_IFACE"; then
        die "Internet uplink '$INTERNET_IFACE' is not UP. Bring it up or fix routing, then retry."
    fi
    echo "OK: Internet uplink $INTERNET_IFACE is UP (default route)"

    for iface in "${ACTIVE_INTERFACES[@]}"; do
        if [ "$iface" = "$INTERNET_IFACE" ]; then
            die "Interface '$iface' is the server internet uplink (default route). Do not use it as a demo LAN uplink in parameters.txt — choose another interface."
        fi
    done

    # Reachability probe is informational only (ICMP/path may be blocked)
    echo "Checking path to 1.1.1.1 (advisory — will not fail setup)..."
    if ip -4 route get 1.1.1.1 2>&1; then
        echo "OK: route lookup for 1.1.1.1 succeeded (connectivity still not required)"
    else
        echo "WARNING: route lookup for 1.1.1.1 failed or is blocked — continuing anyway"
    fi
}

# ---------------------------------------------------------------------------
# 4) Netplan
# ---------------------------------------------------------------------------
configure_netplan() {
    set_step "Configure netplan"

    local tmp_state="/tmp/dynamicwan_configured_interfaces.conf"
    {
        echo "# Dynamic WAN state — managed by setup.sh / cleanup.sh"
        echo "# Generated: $(date -Iseconds)"
        echo "netplan_file=$NETPLAN_FILE"
        echo "internet_interface=$INTERNET_IFACE"
        echo "num_uplinks=$NUM_ACTIVE_UPLINKS"
    } > "$tmp_state"

    # Write a dedicated drop-in only. Netplan merges ALL /etc/netplan/*.yaml;
    # editing 01-network-manager / 50-cloud-init / 90-NM-* is unsafe and unclear.
    local i ip_addr prefix
    {
        echo "# Generated by sa_demo_kit_v2 setup.sh — safe to delete via cleanup.sh"
        echo "# Do not hand-edit unrelated netplan files for this demo."
        echo "network:"
        echo "  version: 2"
        echo "  renderer: $NETPLAN_RENDERER"
        echo "  ethernets:"
        for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
            ip_addr=$(echo "${ACTIVE_LAN_IPS[i]}" | cut -d/ -f1)
            prefix=$(echo "${ACTIVE_LAN_IPS[i]}" | cut -d/ -f2)
            echo "interface=${ACTIVE_INTERFACES[i]}" >> "$tmp_state"
            echo "lan_ip=${ACTIVE_LAN_IPS[i]}" >> "$tmp_state"
            echo "lan_subnet=${ACTIVE_LAN_SUBNETS[i]}" >> "$tmp_state"
            echo "    ${ACTIVE_INTERFACES[i]}:"
            echo "      dhcp4: false"
            echo "      optional: true"
            echo "      addresses:"
            echo "        - ${ip_addr}/${prefix}"
        done
    } | sudo tee "$NETPLAN_FILE" >/dev/null || die "Failed to write $NETPLAN_FILE"

    sudo chmod 600 "$NETPLAN_FILE" 2>/dev/null || true
    echo "Wrote dedicated netplan drop-in: $NETPLAN_FILE"
    echo "(Other yaml files under /etc/netplan/ are left untouched; netplan merges them all.)"

    if ! sudo netplan apply; then
        echo "netplan apply output/diagnostics:" >&2
        sudo netplan --debug apply 2>&1 | tail -40 >&2 || true
        die "netplan apply failed after writing $NETPLAN_FILE (see diagnostics above)"
    fi

    NETPLAN_DONE=true
    sleep 2

    # Ensure addresses are present. NetworkManager often skips DOWN/no-carrier
    # ifaces after netplan apply — fall back to ip addr add (works while DOWN).
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        local iface="${ACTIVE_INTERFACES[i]}"
        ip_addr=$(echo "${ACTIVE_LAN_IPS[i]}" | cut -d/ -f1)
        prefix=$(echo "${ACTIVE_LAN_IPS[i]}" | cut -d/ -f2)

        if ip -4 addr show "$iface" | grep -q "inet ${ip_addr}/"; then
            echo "OK: $iface has ${ACTIVE_LAN_IPS[i]}"
            continue
        fi

        echo "NOTE: $iface has no ${ACTIVE_LAN_IPS[i]} after netplan apply — assigning with ip addr add"
        echo "      (common when link is DOWN / no-carrier under NetworkManager)"
        if ! sudo ip addr add "${ip_addr}/${prefix}" dev "$iface" 2>/tmp/dynamicwan_ip_addr_err; then
            if grep -qiE 'File exists|already assigned' /tmp/dynamicwan_ip_addr_err 2>/dev/null; then
                :
            else
                echo "ip addr add failed for $iface:" >&2
                cat /tmp/dynamicwan_ip_addr_err >&2 || true
            fi
        fi
        rm -f /tmp/dynamicwan_ip_addr_err

        if ip -4 addr show "$iface" | grep -q "inet ${ip_addr}/"; then
            echo "OK: $iface now has ${ACTIVE_LAN_IPS[i]} (via ip addr add)"
            continue
        fi

        echo "WARNING: could not verify IP ${ACTIVE_LAN_IPS[i]} on $iface yet"
        echo "--- ip link show $iface ---"
        ip link show "$iface" || true
        echo "--- ip -4 addr show $iface ---"
        ip -4 addr show "$iface" || true
        if iface_is_up "$iface"; then
            die "Netplan/config written, but $iface is UP and still has no ${ACTIVE_LAN_IPS[i]}. Check renderer/NetworkManager ownership of $iface."
        fi
        echo "Continuing: $iface is DOWN — netplan entry is saved; IP should appear when the link is brought up."
    done

    # netplan apply (NetworkManager) often briefly drops Wi‑Fi/default route.
    # Wait/retry; if still no default route, keep the pre-netplan internet iface
    # when it is still present and UP — do not fail the whole setup for a bounce.
    local inet_now="" attempt
    local saved_internet="$INTERNET_IFACE"
    echo "Re-checking internet uplink after netplan apply (NM may bounce briefly)..."
    for attempt in 1 2 3 4 5 6; do
        inet_now=$(detect_internet_iface)
        if [ -n "$inet_now" ]; then
            break
        fi
        echo "  attempt $attempt/6: no default route yet — waiting..."
        sleep 2
    done

    if [ -n "$inet_now" ]; then
        if [ "$inet_now" != "$saved_internet" ]; then
            echo "NOTE: internet iface changed after netplan: $saved_internet -> $inet_now"
        fi
        INTERNET_IFACE="$inet_now"
        echo "OK: internet uplink $INTERNET_IFACE (default route restored)"
    elif iface_exists "$saved_internet" && iface_is_up "$saved_internet"; then
        INTERNET_IFACE="$saved_internet"
        echo "WARNING: default route not seen yet after netplan apply"
        echo "         Continuing with previously detected internet uplink: $INTERNET_IFACE"
        echo "         (common with NetworkManager + Wi‑Fi; route usually returns shortly)"
        echo "--- current default routes ---"
        ip -4 route show default || true
        echo "--- $INTERNET_IFACE ---"
        ip -4 addr show "$INTERNET_IFACE" || true
    else
        echo "--- diagnostics ---" >&2
        ip -4 route show default >&2 || true
        ip -4 route >&2 || true
        ip link show "$saved_internet" >&2 || true
        die "Internet uplink lost after netplan apply (no default route, and '$saved_internet' is not UP). Check Wi‑Fi/NetworkManager."
    fi

    sed -i "s/^internet_interface=.*/internet_interface=$INTERNET_IFACE/" "$tmp_state"

    for iface in "${ACTIVE_INTERFACES[@]}"; do
        [ "$iface" != "$INTERNET_IFACE" ] || die "Internet uplink collided with LAN iface after netplan"
    done

    PREV_IP_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
    echo "ip_forward_previous=$PREV_IP_FORWARD" >> "$tmp_state"

    sudo mv "$tmp_state" "$STATE_FILE"
    sudo chmod 644 "$STATE_FILE"
    echo "State file: $STATE_FILE"
}

# ---------------------------------------------------------------------------
# 5) NAT
# ---------------------------------------------------------------------------
setup_nat() {
    set_step "Configure NAT and IP forwarding"

    local lan_list="" i
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        lan_list+="${ACTIVE_INTERFACES[i]} "
    done
    lan_list=${lan_list%% }

    sudo tee "$NAT_SCRIPT" >/dev/null <<EOF
#!/bin/bash
set -euo pipefail
INTERNET_IFACE="$INTERNET_IFACE"
LAN_IFACES=($lan_list)

add_nat() {
    if ! iptables -t nat -C "\$@" >/dev/null 2>&1; then
        iptables -t nat -A "\$@"
    fi
}
add_fwd() {
    if ! iptables -C "\$@" >/dev/null 2>&1; then
        iptables -A "\$@"
    fi
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null
add_nat POSTROUTING -o "\$INTERNET_IFACE" -j MASQUERADE -m comment --comment "dynamicwan"
for lan in "\${LAN_IFACES[@]}"; do
    add_fwd FORWARD -i "\$lan" -o "\$INTERNET_IFACE" -j ACCEPT -m comment --comment "dynamicwan"
    add_fwd FORWARD -i "\$INTERNET_IFACE" -o "\$lan" -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "dynamicwan"
done
EOF
    sudo chmod +x "$NAT_SCRIPT"

    if [ "$PREV_IP_FORWARD" != "1" ]; then
        if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf >/dev/null
            echo "ip_forward_modified=1" | sudo tee -a "$STATE_FILE" >/dev/null
            SYSCTL_MODIFIED=true
        fi
    else
        echo "ip_forward_modified=0" | sudo tee -a "$STATE_FILE" >/dev/null
    fi

    sudo "$NAT_SCRIPT" || die "Failed to apply NAT rules"

    sudo tee "/etc/systemd/system/${NAT_SERVICE}" >/dev/null <<EOF
[Unit]
Description=Dynamic WAN NAT and IP Forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NAT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$NAT_SERVICE" >/dev/null
    sudo systemctl restart "$NAT_SERVICE" || die "Failed to start $NAT_SERVICE"
    NAT_DONE=true
    echo "OK: NAT via $INTERNET_IFACE for LAN: $lan_list"
}

# ---------------------------------------------------------------------------
# 6) Config files + images + containers
# ---------------------------------------------------------------------------
create_frr_daemons() {
    cat > "$SCRIPT_DIR/daemons" <<'EOF'
zebra=yes
bgpd=no
ospfd=yes
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
vtysh_enable=yes
zebra_options=" -s 90000000 --daemon -A 127.0.0.1"
bgpd_options="   --daemon -A 127.0.0.1"
ospfd_options="  --daemon -A 127.0.0.1"
ospf6d_options=" --daemon -A ::1"
ripd_options="   --daemon -A 127.0.0.1"
ripngd_options=" --daemon -A ::1"
isisd_options="  --daemon -A 127.0.0.1"
pimd_options="  --daemon -A 127.0.0.1"
ldpd_options="  --daemon -A 127.0.0.1"
nhrpd_options="  --daemon -A 127.0.0.1"
eigrpd_options="  --daemon -A 127.0.0.1"
babeld_options="  --daemon -A 127.0.0.1"
sharpd_options="  --daemon -A 127.0.0.1"
staticd_options="  --daemon -A 127.0.0.1"
pbrd_options="  --daemon -A 127.0.0.1"
bfdd_options="  --daemon -A 127.0.0.1"
fabricd_options="  --daemon -A 127.0.0.1"
EOF
}

generate_frr_config() {
    local cfg="$SCRIPT_DIR/frr_dyn.conf" i
    cat > "$cfg" <<EOF
frr version 8.4_git
frr defaults traditional
hostname frr
log stdout
ip forwarding
no ipv6 forwarding
!
EOF
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        cat >> "$cfg" <<EOF
interface ${ACTIVE_INTERFACES[i]}
 ip address ${ACTIVE_LAN_IPS[i]}
 ip ospf network point-to-point
!
EOF
    done
    cat >> "$cfg" <<EOF
router ospf
 ospf router-id 1.1.1.1
EOF
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        echo " network ${ACTIVE_LAN_SUBNETS[i]} area 0" >> "$cfg"
    done
    cat >> "$cfg" <<'EOF'
 default-information originate always
!
line vty
!
EOF
}

create_dhcp_assets() {
    local i all_ifaces=""
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        all_ifaces+="${ACTIVE_INTERFACES[i]} "
    done
    all_ifaces=${all_ifaces%% }

    cat > "$SCRIPT_DIR/dhcpdContainerfile" <<'EOF'
FROM ubuntu:latest
RUN apt-get update && apt-get install -y iproute2 isc-dhcp-server freeradius-utils \
    && rm -rf /var/lib/apt/lists/*
COPY dhcpdStartup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh
COPY ./dhcpd.conf /etc/dhcp/dhcpd.conf
RUN touch /var/lib/dhcp/dhcpd.leases
CMD ["/usr/local/bin/startup.sh"]
EOF

    cat > "$SCRIPT_DIR/dhcpdStartup.sh" <<EOF
#!/bin/bash
set -e
echo "\$(date): Starting Dynamic WAN DHCP" >> /var/log/startup.log
/usr/sbin/dhcpd -cf /etc/dhcp/dhcpd.conf -pf /var/run/dhcpd.pid $all_ifaces
tail -f /var/log/startup.log
EOF
    chmod +x "$SCRIPT_DIR/dhcpdStartup.sh"

    cat > "$SCRIPT_DIR/dhcpd.conf" <<EOF
option domain-name "dynamicwan.local";
option domain-name-servers 8.8.8.8, 8.8.4.4;
default-lease-time 600;
max-lease-time 7200;
ddns-update-style none;
authoritative;
EOF
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        cat >> "$SCRIPT_DIR/dhcpd.conf" <<EOF
subnet ${ACTIVE_LAN_NET_ADDRS[i]} netmask 255.255.255.252 {
}
EOF
    done
    # Lab client pools (same as original demo kit)
    cat >> "$SCRIPT_DIR/dhcpd.conf" <<'EOF'
subnet 192.168.18.0 netmask 255.255.255.0 {
  range 192.168.18.11 192.168.18.254;
  option domain-name-servers 8.8.8.8;
  option domain-name "dynamicwan.local";
  option subnet-mask 255.255.255.0;
  option routers 192.168.18.1;
  option broadcast-address 192.168.18.255;
  default-lease-time 600;
  max-lease-time 7200;
}
subnet 192.168.19.0 netmask 255.255.255.0 {
  range 192.168.19.11 192.168.19.254;
  option domain-name-servers 8.8.8.8;
  option domain-name "dynamicwan.local";
  option subnet-mask 255.255.255.0;
  option routers 192.168.19.1;
  option broadcast-address 192.168.19.255;
  default-lease-time 600;
  max-lease-time 7200;
}
subnet 192.168.20.0 netmask 255.255.255.0 {
  range 192.168.20.11 192.168.20.254;
  option domain-name-servers 8.8.8.8;
  option domain-name "dynamicwan.local";
  option subnet-mask 255.255.255.0;
  option routers 192.168.20.1;
  option broadcast-address 192.168.20.255;
  default-lease-time 600;
  max-lease-time 7200;
}
subnet 192.168.21.0 netmask 255.255.255.0 {
  range 192.168.21.11 192.168.21.254;
  option domain-name-servers 8.8.8.8;
  option domain-name "dynamicwan.local";
  option subnet-mask 255.255.255.0;
  option routers 192.168.21.1;
  option broadcast-address 192.168.21.255;
  default-lease-time 600;
  max-lease-time 7200;
}
EOF
}

create_radius_assets() {
    cat > "$SCRIPT_DIR/clients.conf" <<EOF
client local1 {
 ipaddr = 127.0.0.1
 proto = *
 secret = nile123
}
client hol1 {
 ipaddr = 172.16.0.0/16
 proto = *
 secret = nile123
}
client hol2 {
 ipaddr = 192.168.0.0/16
 proto = *
 secret = nile123
}
client hol3 {
 ipaddr = 10.0.0.0/8
 proto = *
 secret = nile123
}
EOF

    cat > "$SCRIPT_DIR/dictionary.nile" <<'EOF'
VENDOR          Nile            58313

BEGIN-VENDOR    Nile

ATTRIBUTE       redirect-url  1   string
ATTRIBUTE       netseg        2   string
ATTRIBUTE       nile-avpair   3   string

END-VENDOR      Nile
EOF

    cat > "$SCRIPT_DIR/authorize" <<'EOF'
bob     Cleartext-Password := "hello"
        Reply-Message := "Hello, %{User-Name}"

employee      Cleartext-Password := "nilesecure"
              netseg = "Employee"

contractor    Cleartext-Password := "nilesecure"
              netseg = "contractor"
sally@nilenetworks.com      Cleartext-Password := "nilesecure"
              netseg = "corporate"
harry-ext@nilenetworks.com      Cleartext-Password := "nilesecure"
              netseg = "contractor"
EOF

    cat > "$SCRIPT_DIR/radiusdContainerfile" <<'EOF'
FROM docker.io/freeradius/freeradius-server:latest
RUN apt-get update && apt-get install -y iproute2 freeradius-utils \
    && rm -rf /var/lib/apt/lists/*
COPY ./clients.conf /etc/raddb/clients.conf
COPY ./authorize /etc/raddb/mods-config/files/authorize
COPY ./dictionary.nile /usr/share/freeradius/dictionary.nile
RUN cd /etc/raddb/certs && rm -f *.pem *.key *.crt *.p12 *.txt *.crl *.der *.old *.csr *.mk && ./bootstrap
EOF
}

ensure_images() {
    set_step "Build Docker images (if needed)"
    if ! sudo docker image inspect dhcpd >/dev/null 2>&1; then
        sudo docker build -t dhcpd -f "$SCRIPT_DIR/dhcpdContainerfile" "$SCRIPT_DIR" \
            || die "Failed to build dhcpd image"
    else
        # Rebuild when startup/conf changed — always rebuild dhcpd (binds config at build time)
        sudo docker build -t dhcpd -f "$SCRIPT_DIR/dhcpdContainerfile" "$SCRIPT_DIR" \
            || die "Failed to build dhcpd image"
    fi
    echo "OK: dhcpd image"

    sudo docker build -t radiusd -f "$SCRIPT_DIR/radiusdContainerfile" "$SCRIPT_DIR" \
        || die "Failed to build radiusd image"
    echo "OK: radiusd image"

    sudo docker pull docker.io/frrouting/frr >/dev/null || die "Failed to pull FRR image"
    echo "OK: frrouting/frr image"
}

recreate_container() {
    local name="$1"
    shift
    if sudo docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        sudo docker stop "$name" >/dev/null 2>&1 || true
        sudo docker rm "$name" >/dev/null 2>&1 || true
    fi
    sudo docker run "$@" || die "Failed to start container $name"
    echo "OK: started $name"
}

start_containers() {
    set_step "Start containers"
    CONTAINERS_STARTED=true

    recreate_container frr_dyn -dt --name frr_dyn --network=host --privileged --restart=always \
        -v "$SCRIPT_DIR/frr_dyn.conf:/etc/frr/frr.conf:Z" \
        -v "$SCRIPT_DIR/daemons:/etc/frr/daemons:Z" \
        docker.io/frrouting/frr

    recreate_container dhcpd_dyn -dt --name dhcpd_dyn --network=host --privileged --restart=always \
        dhcpd

    recreate_container radiusd_dyn -dt --name radiusd_dyn --network=host --privileged --restart=always \
        radiusd
}

postflight() {
    set_step "Postflight verification"
    local c
    for c in frr_dyn dhcpd_dyn radiusd_dyn; do
        sudo docker ps --format '{{.Names}}' | grep -qx "$c" \
            || die "Container $c is not running after start"
        echo "OK: $c running"
    done

    local i ip_addr iface
    for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
        iface="${ACTIVE_INTERFACES[i]}"
        ip_addr=$(echo "${ACTIVE_LAN_IPS[i]}" | cut -d/ -f1)
        if ip -4 addr show "$iface" | grep -q "inet ${ip_addr}/"; then
            echo "OK: $iface has ${ACTIVE_LAN_IPS[i]}"
        elif iface_is_up "$iface"; then
            die "LAN IP ${ACTIVE_LAN_IPS[i]} missing on UP interface $iface after setup"
        else
            echo "WARNING: $iface is DOWN without verified IP yet — OK to bring up later"
        fi
    done

    [ -n "$(detect_internet_iface)" ] || die "Internet default route missing after setup"
    echo "OK: internet uplink $(detect_internet_iface) still present"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Dynamic WAN Setup"
echo "================="
echo "Work dir: $SCRIPT_DIR"

parse_parameters
check_dependencies
preflight_checks

echo ""
echo "Summary:"
echo "  Internet uplink: $INTERNET_IFACE"
for ((i=0; i<NUM_ACTIVE_UPLINKS; i++)); do
    echo "  LAN $((i+1)): ${ACTIVE_INTERFACES[i]} ${ACTIVE_LAN_IPS[i]}"
done
echo ""
read -r -p "Continue with setup? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { ROLLBACK_ENABLED=false; echo "Cancelled."; exit 0; }

configure_netplan
setup_nat

set_step "Generate service configs"
create_frr_daemons
generate_frr_config
create_dhcp_assets
create_radius_assets

ensure_images
start_containers
postflight

ROLLBACK_ENABLED=false
trap - ERR EXIT

echo ""
echo "Setup complete."
echo "  Internet NAT: $INTERNET_IFACE"
echo "  Active LANs:  $NUM_ACTIVE_UPLINKS"
echo "  Containers:   frr_dyn, dhcpd_dyn, radiusd_dyn"
echo "  State file:   $STATE_FILE"
echo "  Cleanup:      sudo ./cleanup.sh"

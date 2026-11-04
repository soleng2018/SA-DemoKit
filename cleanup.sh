#!/bin/bash
# Dynamic WAN cleanup — reverses only changes made by setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PARAMS_FILE="$SCRIPT_DIR/parameters.txt"
STATE_FILE="/etc/dynamicwan_configured_interfaces.conf"
NAT_SCRIPT="/usr/local/bin/setup-nat-dynamicwan.sh"
NAT_SERVICE="setup-nat-dynamicwan.service"
# Default dedicated drop-in written by setup.sh (all /etc/netplan/*.yaml are merged)
DEFAULT_NETPLAN_FILE="/etc/netplan/99-dynamicwan-uplinks.yaml"

declare -a INTERFACES=()
declare -a LAN_IPS=()
INTERNET_IFACE=""
NETPLAN_FILE=""
IP_FORWARD_PREV=""
IP_FORWARD_MODIFIED="0"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

_iptables_del_nat() {
    if sudo iptables -t nat -C "$@" >/dev/null 2>&1; then
        sudo iptables -t nat -D "$@" || true
        echo "  removed NAT rule: $*"
    fi
}

_iptables_del_filter() {
    if sudo iptables -C "$@" >/dev/null 2>&1; then
        sudo iptables -D "$@" || true
        echo "  removed FORWARD rule: $*"
    fi
}

_netplan_remove_iface() {
    local iface="$1" netplan_file="$2"
    sudo python3 -c "
import yaml
with open('$netplan_file') as f:
    cfg = yaml.safe_load(f) or {}
eth = (cfg.get('network') or {}).get('ethernets') or {}
if '$iface' in eth:
    del eth['$iface']
    with open('$netplan_file', 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
    print('  removed $iface from netplan')
else:
    print('  $iface not present in netplan (nothing to remove)')
"
}

# ---------------------------------------------------------------------------
# Load what setup recorded (preferred) or parameters.txt (fallback)
# ---------------------------------------------------------------------------
read_state_or_params() {
    INTERFACES=()
    LAN_IPS=()
    INTERNET_IFACE=""
    NETPLAN_FILE=""
    IP_FORWARD_PREV=""
    IP_FORWARD_MODIFIED="0"

    if [ -f "$STATE_FILE" ]; then
        echo "Using state file: $STATE_FILE"
        local pending_iface=""
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            case "$line" in
                interface=*)
                    # Flush previous incomplete pair
                    if [ -n "$pending_iface" ]; then
                        INTERFACES+=("$pending_iface")
                        LAN_IPS+=("")
                    fi
                    pending_iface="${line#interface=}"
                    ;;
                lan_ip=*)
                    if [ -n "$pending_iface" ]; then
                        INTERFACES+=("$pending_iface")
                        LAN_IPS+=("${line#lan_ip=}")
                        pending_iface=""
                    fi
                    ;;
                internet_interface=*)
                    INTERNET_IFACE="${line#internet_interface=}"
                    ;;
                netplan_file=*)
                    NETPLAN_FILE="${line#netplan_file=}"
                    ;;
                ip_forward_previous=*)
                    IP_FORWARD_PREV="${line#ip_forward_previous=}"
                    ;;
                ip_forward_modified=*)
                    IP_FORWARD_MODIFIED="${line#ip_forward_modified=}"
                    ;;
            esac
        done < "$STATE_FILE"
        if [ -n "$pending_iface" ]; then
            INTERFACES+=("$pending_iface")
            LAN_IPS+=("")
        fi
    else
        echo "State file not found — falling back to parameters.txt"
        echo "(Cleanup will still reverse known demo artifacts.)"
        [ -f "$PARAMS_FILE" ] || die "Neither $STATE_FILE nor $PARAMS_FILE found — nothing to clean"

        local line key val i
        declare -A P=()
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^uplink[1-4]_(interface|lan_ip)= ]] || continue
            key="${line%%=*}"
            val="${line#*=}"
            val="${val#\"}"
            val="${val%\"}"
            P["$key"]="$val"
        done < "$PARAMS_FILE"

        for i in 1 2 3 4; do
            val="${P[uplink${i}_interface]:-}"
            [ -n "$val" ] || continue
            INTERFACES+=("$val")
            LAN_IPS+=("${P[uplink${i}_lan_ip]:-}")
        done

        NETPLAN_FILE="$DEFAULT_NETPLAN_FILE"
        INTERNET_IFACE=$(ip -4 route show default 2>/dev/null | awk '{
            for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit }
        }' || true)
    fi

    # Prefer dedicated drop-in from setup; never guess "first yaml alphabetically"
    if [ -z "$NETPLAN_FILE" ] || [ "$NETPLAN_FILE" = "/etc/netplan/" ]; then
        NETPLAN_FILE="$DEFAULT_NETPLAN_FILE"
    fi
}

# True if SSH client appears to reach us via a demo LAN uplink (session may drop)
warn_if_ssh_on_lan() {
    local ssh_client="" local_ip="" i lan_ip lan_host
    # SSH_CONNECTION: client_ip client_port server_ip server_port
    if [ -n "${SSH_CONNECTION:-}" ]; then
        ssh_client=$(echo "$SSH_CONNECTION" | awk '{print $1}')
        local_ip=$(echo "$SSH_CONNECTION" | awk '{print $3}')
    fi

    echo ""
    echo "--------------------------------------------------------------------"
    echo "IMPORTANT — SSH / remote session warning"
    echo "--------------------------------------------------------------------"
    if [ -n "$ssh_client" ]; then
        echo "This SSH session: client $ssh_client -> server $local_ip"
    else
        echo "No SSH_CONNECTION env detected (local console or non-SSH)."
    fi
    if [ -n "${INTERNET_IFACE:-}" ]; then
        local wifi_ip
        wifi_ip=$(ip -4 -o addr show dev "$INTERNET_IFACE" 2>/dev/null | awk '{print $4}' | head -1)
        echo "Preferred reconnect IP (internet uplink $INTERNET_IFACE): ${wifi_ip:-unknown}"
    fi

    local risk=false
    for ((i=0; i<${#INTERFACES[@]}; i++)); do
        lan_ip="${LAN_IPS[i]:-}"
        [ -n "$lan_ip" ] || continue
        lan_host="${lan_ip%%/*}"
        if [ -n "$local_ip" ] && [ "$local_ip" = "$lan_host" ]; then
            risk=true
            echo "WARNING: You are SSH'd to the demo LAN address $lan_host on ${INTERFACES[i]}."
        fi
        # Client on same /30 or same first three octets as demo LAN (e.g. 172.16.250.2)
        if [ -n "$ssh_client" ] && [ -n "$lan_host" ]; then
            if [[ "$ssh_client" == "${lan_host%.*}."* ]] || [[ "$ssh_client" == 172.16.* && "$lan_host" == 172.16.* ]]; then
                # tighter: same /24 prefix match for warning
                if [ "$(echo "$ssh_client" | cut -d. -f1-3)" = "$(echo "$lan_host" | cut -d. -f1-3)" ]; then
                    risk=true
                    echo "WARNING: SSH client $ssh_client looks like it is on demo LAN ${INTERFACES[i]} ($lan_ip)."
                fi
            fi
        fi
    done

    if [ "$risk" = true ]; then
        echo ""
        echo "Removing the LAN IP / stopping FRR will DROP this SSH session."
        echo "Reconnect using the internet/Wi‑Fi address (e.g. 192.168.1.13), then"
        echo "re-run cleanup.sh if it did not finish."
        echo ""
        read -r -p "Continue anyway? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cleanup cancelled."; exit 0; }
    else
        echo "No clear sign that SSH is over the demo LAN — still, prefer Wi‑Fi/management IP."
    fi
    echo "--------------------------------------------------------------------"
}

show_cleanup_plan() {
    echo ""
    echo "Cleanup plan (only reverses setup.sh changes):"
    echo "  1) Stop/remove containers: frr_dyn, dhcpd_dyn, radiusd_dyn"
    echo "  2) Remove setup-owned NAT/FORWARD rules (comment: dynamicwan)"
    echo "  3) Remove NAT systemd unit + $NAT_SCRIPT"
    if [ "$IP_FORWARD_MODIFIED" = "1" ]; then
        echo "  4) Restore ip_forward to previous value: ${IP_FORWARD_PREV:-0}"
    else
        echo "  4) Leave ip_forward unchanged"
    fi
    echo "  5) Remove dedicated netplan drop-in: ${NETPLAN_FILE:-$DEFAULT_NETPLAN_FILE}"
    if [ ${#INTERFACES[@]} -eq 0 ]; then
        echo "  6) No LAN runtime IPs recorded"
    else
        local i
        for ((i=0; i<${#INTERFACES[@]}; i++)); do
            echo "  6) LAN ${INTERFACES[i]}: remove runtime IP ${LAN_IPS[i]:-(unknown)}"
        done
    fi
    echo "  7) Delete generated config files + state file"
    echo "  • Keep packages and Docker images"
    echo ""
    echo "Note: Steps 5–6 may drop SSH if you are connected via the demo LAN"
    echo "      (e.g. client 172.16.250.x). Use the Wi‑Fi/management IP instead."
}

# ---------------------------------------------------------------------------
# Reverse each setup step
# ---------------------------------------------------------------------------
cleanup_containers() {
    echo "==> Stop/remove demo containers"
    if ! command -v docker >/dev/null 2>&1; then
        echo "  docker not installed — skip"
        return 0
    fi
    local c
    for c in frr_dyn dhcpd_dyn radiusd_dyn; do
        if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
            sudo docker stop "$c" >/dev/null 2>&1 || true
            sudo docker rm "$c" >/dev/null 2>&1 || true
            echo "  removed $c"
        else
            echo "  not found: $c"
        fi
    done
    echo "  (images dhcpd / radiusd / frrouting/frr kept for reuse)"
}

cleanup_runtime_ips() {
    echo "==> Remove runtime LAN IPs applied by setup (ip addr / netplan)"
    # setup may have used 'ip addr add' when the link was DOWN — remove those
    # specific addresses only (does not wipe unrelated IPs on the iface).
    local i iface lan_ip
    if [ ${#INTERFACES[@]} -eq 0 ]; then
        echo "  no LAN interfaces recorded — skip"
        return 0
    fi

    for ((i=0; i<${#INTERFACES[@]}; i++)); do
        iface="${INTERFACES[i]}"
        lan_ip="${LAN_IPS[i]:-}"
        if ! ip link show "$iface" &>/dev/null; then
            echo "  $iface: interface not present — skip IP removal"
            continue
        fi
        if [ -z "$lan_ip" ]; then
            echo "  $iface: no lan_ip recorded — skip runtime IP removal"
            continue
        fi
        if ip -4 addr show dev "$iface" | grep -q "inet ${lan_ip%%/*}/"; then
            if sudo ip addr del "$lan_ip" dev "$iface" 2>/dev/null; then
                echo "  $iface: removed $lan_ip"
            else
                # try without failing cleanup
                echo "  $iface: could not remove $lan_ip (may already be gone)"
            fi
        else
            echo "  $iface: $lan_ip not present (already cleared or never applied)"
        fi
    done
}

cleanup_nat() {
    echo "==> Revert NAT / IP forwarding (setup-owned only)"

    if [ -n "$INTERNET_IFACE" ]; then
        _iptables_del_nat POSTROUTING -o "$INTERNET_IFACE" -j MASQUERADE -m comment --comment "dynamicwan"
        local iface
        for iface in "${INTERFACES[@]}"; do
            _iptables_del_filter FORWARD -i "$iface" -o "$INTERNET_IFACE" -j ACCEPT -m comment --comment "dynamicwan"
            _iptables_del_filter FORWARD -i "$INTERNET_IFACE" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "dynamicwan"
        done
    else
        echo "  no internet iface recorded — skipping iptables rule removal"
    fi

    if [ -f "/etc/systemd/system/${NAT_SERVICE}" ]; then
        sudo systemctl stop "$NAT_SERVICE" >/dev/null 2>&1 || true
        sudo systemctl disable "$NAT_SERVICE" >/dev/null 2>&1 || true
        sudo rm -f "/etc/systemd/system/${NAT_SERVICE}"
        echo "  removed unit $NAT_SERVICE"
    else
        echo "  NAT unit not present"
    fi

    if [ -f "$NAT_SCRIPT" ]; then
        sudo rm -f "$NAT_SCRIPT"
        echo "  removed $NAT_SCRIPT"
    else
        echo "  NAT script not present"
    fi
    sudo systemctl daemon-reload >/dev/null 2>&1 || true

    if [ "$IP_FORWARD_MODIFIED" = "1" ]; then
        local restore="${IP_FORWARD_PREV:-0}"
        echo "$restore" | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
        sudo sed -i '/^net\.ipv4\.ip_forward=1$/d' /etc/sysctl.conf 2>/dev/null || true
        echo "  restored ip_forward=$restore (and removed setup line from sysctl.conf if present)"
    else
        echo "  ip_forward left unchanged"
    fi
}

cleanup_netplan() {
    echo "==> Revert netplan (dedicated Dynamic WAN drop-in only)"

    local target="${NETPLAN_FILE:-$DEFAULT_NETPLAN_FILE}"
    # Safety: only delete our dedicated file, never 01-/50-/90-NM-* by guessing
    if [[ "$target" != *dynamicwan* ]]; then
        echo "WARNING: state netplan_file='$target' is not the dedicated drop-in."
        echo "         Falling back to: $DEFAULT_NETPLAN_FILE"
        target="$DEFAULT_NETPLAN_FILE"
    fi

    if [ -f "$target" ]; then
        sudo rm -f "$target"
        echo "  removed $target"
    else
        echo "  $target not present — nothing to remove from netplan"
    fi

    if sudo netplan apply; then
        echo "  netplan apply succeeded"
    else
        echo "WARNING: netplan apply failed — you may need: sudo netplan apply"
        echo "         (often harmless if Wi‑Fi/NM bounced briefly)"
    fi
}

cleanup_files() {
    echo "==> Remove generated config / temp files"
    local f
    for f in \
        frr_dyn.conf daemons \
        dhcpdContainerfile dhcpdStartup.sh dhcpd.conf \
        clients.conf authorize dictionary.nile \
        radiusdContainerfile default
    do
        if [ -f "$SCRIPT_DIR/$f" ]; then
            rm -f "$SCRIPT_DIR/$f"
            echo "  removed $f"
        fi
    done
    sudo rm -f "$STATE_FILE" \
        /tmp/dynamicwan_configured_interfaces.conf \
        /tmp/dynamicwan_ip_addr_err
    echo "  state/temp files cleared"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Dynamic WAN Cleanup"
echo "==================="
echo "Work dir: $SCRIPT_DIR"
echo "This reverts only changes made by setup.sh."
echo "Installed packages and Docker images are kept."
echo ""

sudo -n true 2>/dev/null || sudo -v || die "sudo privileges required"

read_state_or_params
show_cleanup_plan
warn_if_ssh_on_lan

read -r -p "Proceed with cleanup? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cleanup cancelled — no changes made."; exit 0; }

echo ""
# Do non-path-breaking work first. Remove LAN IPs / netplan last so a dropped
# SSH session loses less progress. Re-run cleanup.sh anytime to finish leftovers.
cleanup_containers
echo ""
cleanup_nat
echo ""

echo "==> About to remove LAN IPs + netplan drop-in (may drop SSH on demo LAN)"
if [ -n "${INTERNET_IFACE:-}" ]; then
    echo "    If disconnected, reconnect to: $(ip -4 -o addr show dev "$INTERNET_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1) ($INTERNET_IFACE)"
fi
sleep 2

cleanup_runtime_ips
echo ""
cleanup_netplan
echo ""
cleanup_files

echo ""
echo "Cleanup complete."
echo "Host should match pre-setup aside from kept packages/images."
echo "Safe to re-run ./cleanup.sh if a previous run was interrupted by SSH drop."

#!/bin/bash

# ==========================================
# OpenVPN Auto-Start & NAT-PMP Monitor Script
# ==========================================

set -u

LOG_FILE='/var/log/start_openvpn.log'
OVPN_CONF='/root/vpn/us.protonvpn.udp.ovpn'
BASE_AUTH='/root/vpn/auth.txt'
RUNTIME_AUTH='/root/vpn/ovpn_auth_runtime.txt'
PID_FILE='/run/openvpn_monitor_openvpn.pid'
LOCK_FILE='/run/lock/openvpn_monitor.lock'
TUN_IF='tun0'
PING_TARGET='1.1.1.1'
MAX_RETRIES=10
VPN_GATEWAY='10.2.0.1'
LEASE_TIME=3600                     # Requested lease time in seconds. ProtonVPN grants at most
                                    # 60s regardless of the request, so this script must run at
                                    # least every ~45s (e.g. via cron/systemd timer) to keep the
                                    # forwarded port alive.

# --- Torrent Client Settings ---
TORRENT_CLIENT='qbittorrent'
QBIT_URL='https://192.168.1.34:8080'
# --insecure: the WebUI uses a self-signed certificate. Anyone on the LAN can
# spoof/intercept this request; install a trusted cert and remove it if possible.
QBIT_CURL_OPTS=(--insecure -s --max-time 10)

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# --- Concurrency Check ---
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "$(date '+%Y-%m-%d %H:%M:%S') - Script is already running. Exiting." >> "$LOG_FILE"; exit 1; }

log_data() {
    local datetime
    datetime=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$datetime - $1" >> "$LOG_FILE"
    echo "$datetime - $1"
}

setup_pmp_auth() {
    if [[ ! -f "$BASE_AUTH" ]]; then
        log_data "CRITICAL ERROR: Base auth file $BASE_AUTH not found. Cannot set up credentials."
        exit 1
    fi

    local username password
    username=$(sed -n '1p' "$BASE_AUTH")
    password=$(sed -n '2p' "$BASE_AUTH")

    if [[ -z "$username" || -z "$password" ]]; then
        log_data "CRITICAL ERROR: $BASE_AUTH must contain the username on line 1 and the password on line 2."
        exit 1
    fi

    username="${username%+pmp}+pmp"

    rm -f "$RUNTIME_AUTH"
    (umask 077; printf '%s\n%s\n' "$username" "$password" > "$RUNTIME_AUTH")

    log_data "Credentials configured with +pmp suffix."
}

check_connection() {
    # Bind the ping to the tunnel so a working WAN route can't mask a dead VPN.
    ip link show "$TUN_IF" > /dev/null 2>&1 &&
        ping -I "$TUN_IF" -c 3 -W 3 "$PING_TARGET" > /dev/null 2>&1
}

log_connection_details() {
    local remote_line proto
    remote_line=$(grep -E '^remote ' "$OVPN_CONF" | head -n 1)
    proto=$(grep -E '^proto ' "$OVPN_CONF" | head -n 1 | awk '{print $2}')

    log_data "--> Config Target: $(awk '{print $2}' <<< "$remote_line")"
    log_data "--> Protocol/Port: ${proto^^} $(awk '{print $3}' <<< "$remote_line")"
}

update_app_port() {
    local active_port=$1
    log_data "Updating $TORRENT_CLIENT to use port $active_port..."

    case "$TORRENT_CLIENT" in
        transmission)
            if ! command -v transmission-remote > /dev/null; then
                log_data "WARNING: transmission-remote not found."
            elif transmission-remote -p "$active_port" > /dev/null 2>&1; then
                log_data "--> Transmission port successfully updated."
            else
                log_data "WARNING: Failed to update Transmission port."
            fi
            ;;
        qbittorrent)
            local http_code
            http_code=$(curl "${QBIT_CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' \
                --data-urlencode "json={\"listen_port\":$active_port}" \
                "$QBIT_URL/api/v2/app/setPreferences")
            if [[ "$http_code" == "200" ]]; then
                log_data "--> qBittorrent port successfully updated."
            else
                log_data "WARNING: qBittorrent WebUI update failed (HTTP ${http_code:-n/a}) at $QBIT_URL."
            fi
            ;;
        *)
            log_data "No valid torrent client specified."
            ;;
    esac
}

request_port_mapping() {
    natpmpc -g "$VPN_GATEWAY" -a 1 0 "$1" "$LEASE_TIME" 2>&1
}

# natpmpc prints: "Mapped public port <port> protocol <PROTO> to local port 0 liftime <secs>"
# (the "liftime" typo is in natpmpc itself).
parse_mapped_port() {
    awk 'tolower($0) ~ /mapped public port/ {print $4; exit}' <<< "$1"
}

check_port_forwarding() {
    if ! command -v natpmpc > /dev/null; then
        log_data "WARNING: 'natpmpc' command not found. Cannot request port forwarding."
        return 1
    fi

    log_data "Requesting NAT-PMP port leases from gateway $VPN_GATEWAY for $LEASE_TIME seconds..."

    # Torrent clients listen on both protocols; map TCP as well as UDP.
    local udp_output tcp_output udp_port tcp_port granted_lifespan
    udp_output=$(request_port_mapping udp)
    tcp_output=$(request_port_mapping tcp)

    udp_port=$(parse_mapped_port "$udp_output")
    tcp_port=$(parse_mapped_port "$tcp_output")
    granted_lifespan=$(awk 'tolower($0) ~ /mapped public port/ {print $NF; exit}' <<< "$tcp_output")

    if [[ ! "$tcp_port" =~ ^[0-9]+$ || "$tcp_port" -eq 0 ]]; then
        log_data "WARNING: Failed to get a port lease via NAT-PMP. Output: $tcp_output"
        return 1
    fi

    log_data "SUCCESS: Port forwarding active. Assigned port: $tcp_port (TCP), ${udp_port:-none} (UDP)."
    if [[ -n "$granted_lifespan" ]]; then
        log_data "--> Server granted a lease time of $granted_lifespan seconds."
    fi
    if [[ "$udp_port" != "$tcp_port" ]]; then
        log_data "WARNING: UDP and TCP mapped ports differ; using the TCP port."
    fi

    update_app_port "$tcp_port"
}

stop_vpn() {
    # Only touch the OpenVPN instance this script manages (or one using our config),
    # never unrelated tunnels.
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(<"$PID_FILE")
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            log_data "Stopping OpenVPN (PID $pid)..."
            kill "$pid" 2>/dev/null
            sleep 2
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
    pkill -f -- "openvpn --config $OVPN_CONF" 2>/dev/null
    return 0
}

start_vpn() {
    log_data "Cleaning up existing OpenVPN instances..."
    stop_vpn
    sleep 2

    log_data "Starting OpenVPN in daemon mode..."
    if ! /usr/sbin/openvpn --config "$OVPN_CONF" --auth-user-pass "$RUNTIME_AUTH" \
            --writepid "$PID_FILE" --daemon; then
        log_data "ERROR: OpenVPN failed to start."
        return 1
    fi

    log_data "Waiting for $TUN_IF to establish..."
    for _ in {1..20}; do
        sleep 1
        if ip link show "$TUN_IF" > /dev/null 2>&1; then
            log_data "Tunnel interface detected. Waiting 3s for routing to settle..."
            sleep 3

            if check_connection; then
                log_data "SUCCESS: VPN connection established and verified."
                return 0
            fi
        fi
    done

    log_data "ERROR: Failed to establish a valid VPN connection within the timeout."
    stop_vpn
    return 1
}

main() {
    log_data "=========================================="
    log_data "Initiating OpenVPN Status Check"
    log_data "=========================================="

    setup_pmp_auth

    if check_connection; then
        log_data "VPN is active and passing traffic."
        log_connection_details
        check_port_forwarding
        exit 0
    fi

    log_data "VPN is down or unresponsive. Initiating connection sequence..."

    local attempt=1
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_data "--- Connection Attempt $attempt of $MAX_RETRIES ---"

        if start_vpn; then
            log_data "Successfully connected after $attempt attempt(s)."
            log_connection_details
            check_port_forwarding
            exit 0
        fi

        log_data "Attempt $attempt failed."
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_data "Waiting 10 seconds before retrying..."
            sleep 10
        fi
        ((attempt++))
    done

    log_data "CRITICAL ERROR: Failed to connect after $MAX_RETRIES attempts. Giving up."
    exit 2
}

main

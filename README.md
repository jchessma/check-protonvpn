# check-protonvpn

A bash script that keeps an OpenVPN connection to ProtonVPN alive, requests a
NAT-PMP forwarded port, and pushes that port to a torrent client
(qBittorrent or Transmission). Designed to run periodically (cron/systemd
timer) so it can both bring the tunnel back up after a drop and keep the
forwarded port lease renewed.

## How it works

Each run:

1. Regenerates a runtime auth file for OpenVPN from your base credentials,
   appending the `+pmp` suffix ProtonVPN requires for NAT-PMP.
2. Checks whether the tunnel (`tun0` by default) is up and passing traffic,
   pinging *through* the tunnel interface specifically.
3. If the tunnel is down, stops any existing instance and starts a new
   OpenVPN connection, retrying up to `MAX_RETRIES` times.
4. Once connected, requests a NAT-PMP port mapping (TCP + UDP) from the VPN
   gateway and updates the configured torrent client's listening port.

ProtonVPN's NAT-PMP server grants leases of ~60 seconds regardless of what's
requested, so this script needs to run at least every ~45 seconds (e.g. via
cron or a systemd timer) to keep the forwarded port alive continuously.

## Requirements

- Linux, run as **root** (writes to `/root/vpn`, `/run`, manages the
  `openvpn` process).
- `openvpn`
- `natpmpc` (for NAT-PMP port forwarding requests)
- `curl` (only needed if using qBittorrent)
- `transmission-remote` (only needed if using Transmission)
- A ProtonVPN account with port forwarding enabled, and an OpenVPN config
  file for a P2P-capable server.

## Setup

1. Create the auth file with your ProtonVPN OpenVPN credentials (**not**
   your regular account password — use the credentials from the ProtonVPN
   dashboard's OpenVPN/IKEv2 section):

   ```bash
   mkdir -p /root/vpn
   printf '%s\n%s\n' 'your-openvpn-username' 'your-openvpn-password' > /root/vpn/auth.txt
   chmod 600 /root/vpn/auth.txt
   ```

   Line 1 is the username, line 2 is the password. The script appends the
   `+pmp` suffix automatically — don't include it yourself.

2. Place your ProtonVPN OpenVPN config at `/root/vpn/us.protonvpn.udp.ovpn`
   (or update `OVPN_CONF` in the script to point elsewhere). Use a server
   that supports P2P/port forwarding.

3. Edit the config variables at the top of `check_protonvpn.sh` as needed
   (see table below).

4. Make it executable and run it once manually to confirm it works:

   ```bash
   chmod +x check_protonvpn.sh
   sudo ./check_protonvpn.sh
   ```

5. Check the log:

   ```bash
   tail -f /var/log/start_openvpn.log
   ```

## Configuration

All settings are plain variables at the top of the script:

| Variable | Purpose |
|---|---|
| `LOG_FILE` | Path to the log file |
| `OVPN_CONF` | Path to the ProtonVPN OpenVPN config |
| `BASE_AUTH` | Path to your username/password file |
| `RUNTIME_AUTH` | Generated auth file (with `+pmp` suffix) passed to OpenVPN |
| `PID_FILE` / `LOCK_FILE` | Process tracking / concurrency lock |
| `TUN_IF` | Tunnel interface name |
| `PING_TARGET` | Host pinged through the tunnel to verify connectivity |
| `MAX_RETRIES` | Connection attempts before giving up |
| `VPN_GATEWAY` | Gateway IP used for NAT-PMP requests |
| `LEASE_TIME` | Requested NAT-PMP lease (ProtonVPN caps it at ~60s regardless) |
| `TORRENT_CLIENT` | `qbittorrent` or `transmission` |
| `QBIT_URL` | qBittorrent WebUI URL |
| `QBIT_CURL_OPTS` | curl options for the WebUI request (defaults to `--insecure` for a self-signed LAN cert — install a trusted cert and remove this if possible) |

## Scheduling

Run frequently enough to keep the port lease alive. Example systemd timer,
firing every 30 seconds:

```ini
# /etc/systemd/system/check-protonvpn.service
[Unit]
Description=ProtonVPN connection & port-forwarding check

[Service]
Type=oneshot
ExecStart=/path/to/check_protonvpn.sh
```

```ini
# /etc/systemd/system/check-protonvpn.timer
[Unit]
Description=Run check-protonvpn every 30s

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now check-protonvpn.timer
```

Or via cron (minimum granularity of 1 minute, which exceeds ProtonVPN's
~60s lease — a systemd timer is preferable):

```
* * * * * /path/to/check_protonvpn.sh
```

## Exit codes

- `0` — VPN up (or successfully brought up) and checks completed.
- `1` — Already running (lock held), not run as root, or a fatal auth/config
  error.
- `2` — Failed to establish the VPN connection after `MAX_RETRIES` attempts.

## Security notes

- The runtime auth file (`RUNTIME_AUTH`) is written with `umask 077` so it's
  never world/group-readable, even momentarily.
- The script only stops the OpenVPN process it started (tracked via PID
  file, falling back to matching on its exact config path) — it never kills
  unrelated OpenVPN tunnels on the same host.
- `QBIT_CURL_OPTS` defaults to `--insecure` because the qBittorrent WebUI
  commonly runs with a self-signed cert on the LAN. If you have a trusted
  cert configured, remove `--insecure`.

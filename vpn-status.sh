#!/bin/bash
# Show VPN status: process, tun interface, and recent openconnect log lines.
if pgrep -f "openconnect --protocol nc" >/dev/null; then
    echo "VPN process: RUNNING"
else
    echo "VPN process: not running"
fi
if ip link show tun0 >/dev/null 2>&1; then
    echo "Tunnel tun0: UP  ($(ip -4 addr show tun0 | awk '/inet/{print $2}'))"
else
    echo "Tunnel tun0: down"
fi
echo "--- last openconnect log lines:"
journalctl -t openconnect --no-pager -n 5 2>/dev/null

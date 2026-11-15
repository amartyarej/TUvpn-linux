#!/bin/bash
# VPN toggle for TU Dortmund (Ivanti Connect Secure via OpenConnect pulse).
# - Not connected: connects in the background. First time it asks for TU
#   credentials and offers to save the password in the GNOME keyring;
#   after that it connects with no prompts at all.
# - Connected: asks for confirmation, then disconnects.
SERVER="${VPN_SERVER:-stud2.vpn.tu-dortmund.de}"
OC="/usr/local/sbin/openconnect"
UA="Pulse-Secure/22.8.5.41063"   # server (ICS 25.1+) rejects older client versions
CONF="${HOME}/.config/tu-vpn.conf"
LOG="${HOME}/scripts/vpn/vpn.log"

if pgrep -f "openconnect --protocol pulse" >/dev/null; then
    if zenity --question --title="VPN" --text="VPN is connected.\nDisconnect now?" \
         --ok-label="Disconnect" --cancel-label="Keep connected" 2>/dev/null; then
        sudo -n /usr/bin/pkill -f "openconnect --protocol pulse" && \
            zenity --info --title="VPN" --timeout=4 --text="VPN disconnected." 2>/dev/null
    fi
    exit 0
fi

if [[ ! -x "$OC" ]]; then
    notify-send "VPN" "openconnect 9.21 not installed - see ~/scripts/vpn/README.md" 2>/dev/null
    exit 1
fi

# Load saved username (plain file, 0600; the password lives in the keyring)
USERNAME=""
[[ -r "$CONF" ]] && . "$CONF"

# Try the keyring for a saved password
PASSWORD=""
if [[ -n "$USERNAME" ]] && command -v secret-tool >/dev/null; then
    PASSWORD=$(secret-tool lookup service tu-vpn username "$USERNAME" 2>/dev/null)
fi

SAVED=0
if [[ -z "$PASSWORD" ]]; then
    USERNAME=$(zenity --entry --title="VPN" --text="TU username:" \
        --entry-text="${USERNAME}" 2>/dev/null) || exit 0
    PASSWORD=$(zenity --password --title="VPN" \
        --text="Password for $USERNAME:" 2>/dev/null) || exit 0
else
    SAVED=1
fi

printf '%s\n' "$PASSWORD" | sudo -n "$OC" --protocol pulse --useragent "$UA" \
    -u "$USERNAME" --passwd-on-stdin --background --syslog "$SERVER" \
    2>>"$LOG"

sleep 5
if pgrep -f "openconnect --protocol pulse" >/dev/null; then
    TUNIP=$(ip -4 addr show tun0 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1)
    zenity --info --title="VPN" --timeout=8 \
        --text="VPN connected to ${SERVER}\nTunnel IP: ${TUNIP:-unknown}\n\n(This window closes by itself.)" 2>/dev/null
    # Offer to remember the password once the credentials proved valid
    if [[ $SAVED -eq 0 ]] && command -v secret-tool >/dev/null; then
        if zenity --question --title="VPN" \
             --text="Save the password in the encrypted GNOME keyring\nso future connections need no input?" \
             --ok-label="Save" --cancel-label="Don't save" 2>/dev/null; then
            printf '%s' "$PASSWORD" | secret-tool store \
                --label="TU VPN password (${USERNAME})" \
                service tu-vpn username "$USERNAME"
            umask 077
            echo "USERNAME='${USERNAME}'" > "$CONF"
        fi
    fi
else
    if [[ $SAVED -eq 1 ]]; then
        # Saved password was rejected (changed?) - forget it, ask again next time
        secret-tool clear service tu-vpn username "$USERNAME" 2>/dev/null
        zenity --error --title="VPN" --timeout=10 \
            --text="The saved password was rejected.\nYou will be asked for credentials again next time." 2>/dev/null
    else
        zenity --error --title="VPN" --timeout=10 \
            --text="Connection failed.\nDetails: journalctl -t openconnect -n 20\nor ~/scripts/vpn/vpn.log" 2>/dev/null
    fi
    exit 1
fi

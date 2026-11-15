# TU Dortmund VPN on Linux (Ivanti Connect Secure, students)

Connect to `stud2.vpn.tu-dortmund.de` with OpenConnect in **pulse protocol** mode,
using a current client version string. Works without the official Ivanti client
(which does not exist for Linux) and without the institute's browser-cookie
workaround (which is broken since the Ivanti upgrade).

The crucial trick: the appliance (ICS 25.1+) **rejects clients that report a
version older than 22.7**. OpenConnect reports an old version by default, so the
connection dies shortly after authentication ("agentd error"). Passing an
up-to-date version string via `--useragent` fixes it.
Background: https://gitlab.com/openconnect/openconnect/-/issues/852 and MR !644/!651.

Tested on Ubuntu 24.04 with OpenConnect v9.21. No 2FA prompt appears in this flow.

## 1. Install dependencies

    sudo apt install -y build-essential pkg-config libgnutls28-dev \
        libxml2-dev zlib1g-dev zenity libsecret-tools

(`zenity` is needed for the optional one-click launcher and tray icon in
steps 4/4b, `libsecret-tools` for the optional password keyring saving;
the plain terminal flow in step 5 works without them.)

## 2. Build OpenConnect 9.21 from source

The version shipped by Ubuntu 24.04 (9.12) is too old; we install the current
upstream release to /usr/local, leaving the distro package untouched.

    mkdir -p /tmp/oc && cd /tmp/oc
    curl -LO https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz
    tar xzf openconnect-9.21.tar.gz && cd openconnect-9.21
    ./configure --prefix=/usr/local --without-openssl --without-lz4 \
        --without-libpskc --without-stoken --without-docs --without-docker-exec
    make -j$(nproc)
    sudo make install && sudo ldconfig

Check: `/usr/local/sbin/openconnect --version` → `OpenConnect version v9.21`.

## 3. Allow passwordless use via sudo

    sudo tee /etc/sudoers.d/openconnect > /dev/null <<'EOF'
    # OpenConnect - no password for members of group "sudo"
    %sudo ALL=(root:root) NOPASSWD: /usr/local/sbin/openconnect
    %sudo ALL=(root:root) NOPASSWD: /usr/sbin/openconnect
    EOF

    sudo tee /etc/sudoers.d/openconnect-stop > /dev/null <<'EOF'
    # Allow stopping the VPN daemon without a password
    %sudo ALL=(root:root) NOPASSWD: /usr/bin/pkill -f openconnect*
    EOF

    sudo chmod 440 /etc/sudoers.d/openconnect /etc/sudoers.d/openconnect-stop
    sudo visudo -cf /etc/sudoers.d/openconnect /etc/sudoers.d/openconnect-stop

(The last command must print `parsed OK`. Replace `%sudo` with your username
if you prefer to restrict it, e.g. `yourname ALL=(root:root) NOPASSWD: ...`.)

## 4. Optional: one-click launcher (connect/disconnect toggle)

Asks for your TU username and password (graphical dialogs), connects in the
background, and offers to **save the password in the encrypted GNOME keyring** —
after that, connecting needs no input at all. Clicking while connected asks for
confirmation before disconnecting.

    mkdir -p ~/scripts/vpn
    cat > ~/scripts/vpn/vpn-toggle.sh <<'SCRIPT'
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
    SCRIPT
    chmod +x ~/scripts/vpn/vpn-toggle.sh

Desktop entry (shows up as "VPN" in the app grid; drag it to the dock):

    cat > ~/.local/share/applications/vpn.desktop <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=VPN
    Comment=Connect (credential dialogs) / Disconnect (toggle)
    Exec=/home/YOURUSER/scripts/vpn/vpn-toggle.sh
    Icon=network-vpn
    Terminal=false
    Categories=Network;
    EOF

Replace `YOURUSER` with your login name, then run
`update-desktop-database ~/.local/share/applications`.

## 4b. Optional: top-bar status icon

A tray icon in the GNOME top bar showing the TU Dortmund block mark — green
when the VPN is connected, grey when not — with Connect / Disconnect / Status
in its menu. Requires the dependency `gir1.2-ayatanaappindicator3-0.1`
(installed by default on Ubuntu desktop) and the preinstalled "Ubuntu
AppIndicator" extension. The icon files (`tu-mark-green.png` /
`tu-mark-grey.png`, 28 px high) are derived from the official logo SVG
(https://www.tu-dortmund.de, green: `#83b818`) by cropping the viewBox to the
TU block mark (`viewBox="0 0 71.06 54.3926"`) and exporting with
`inkscape tu-mark.svg --export-filename=tu-mark-green.png -h 28`; the grey
variant is the same with `#83b818` replaced by `#9e9e9e`. They live in
`~/scripts/vpn/icons/`.

    mkdir -p ~/.config/systemd/user
    cat > ~/scripts/vpn/vpn-indicator.py <<'PYEOF'
    #!/usr/bin/env python3
    """TU Dortmund VPN tray indicator."""
    import gi, os, subprocess
    gi.require_version("AyatanaAppIndicator3", "0.1")
    gi.require_version("Gtk", "3.0")
    from gi.repository import AyatanaAppIndicator3, Gtk, GLib

    TOGGLE = os.path.expanduser("~/scripts/vpn/vpn-toggle.sh")
    ICON_ON = os.path.expanduser("~/scripts/vpn/icons/tu-mark-green.png")
    ICON_OFF = os.path.expanduser("~/scripts/vpn/icons/tu-mark-grey.png")

    def vpn_running():
        # The tunnel interface exists = VPN is up (works regardless of how
        # openconnect was started).
        return subprocess.run(["ip", "link", "show", "tun0"],
                              capture_output=True).returncode == 0

    def vpn_running():
        # The tunnel interface exists = VPN is up (works regardless of how
        # openconnect was started).
        return subprocess.run(["ip", "link", "show", "tun0"],
                              capture_output=True).returncode == 0

    def tunnel_ip():
        out = subprocess.run(["ip", "-4", "addr", "show", "tun0"],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "inet " in line:
                return line.split()[1].split("/")[0]
        return None

    class VpnIndicator:
        def __init__(self):
            self.ind = AyatanaAppIndicator3.Indicator.new(
                "tu-vpn", ICON_OFF,
                AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS)
            self.ind.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
            self.ind.set_title("TU Dortmund VPN")
            self.menu = Gtk.Menu()
            self.state_item = Gtk.MenuItem(label="VPN: checking…")
            self.state_item.set_sensitive(False)
            self.state_item.show()
            self.menu.append(self.state_item)
            sep = Gtk.SeparatorMenuItem(); sep.show(); self.menu.append(sep)
            self.connect_item = Gtk.MenuItem(label="Connect")
            self.connect_item.connect("activate", lambda _: subprocess.Popen([TOGGLE]))
            self.connect_item.show(); self.menu.append(self.connect_item)
            self.disconnect_item = Gtk.MenuItem(label="Disconnect…")
            self.disconnect_item.connect("activate", lambda _: subprocess.Popen([TOGGLE]))
            self.disconnect_item.show(); self.menu.append(self.disconnect_item)
            status_item = Gtk.MenuItem(label="Status…")
            status_item.connect("activate", self.on_status)
            status_item.show(); self.menu.append(status_item)
            self.ind.set_menu(self.menu)
            self.tick()
            GLib.timeout_add_seconds(3, self.tick)

        def on_status(self, _):
            if vpn_running():
                text = (f"VPN connected to stud2.vpn.tu-dortmund.de\n"
                        f"Tunnel IP: {tunnel_ip() or 'unknown'}")
            else:
                text = "VPN is not connected."
            subprocess.Popen(["zenity", "--info", "--title=VPN", "--timeout=8",
                              f"--text={text}"])

        def tick(self):
            up = vpn_running()
            if up != getattr(self, "_last_up", None):
                self.ind.set_icon_full(ICON_ON if up else ICON_OFF, "TU Dortmund VPN")
                self._last_up = up
            self.state_item.set_label(
                f"VPN: connected ({tunnel_ip() or '…'})" if up else "VPN: not connected")
            self.connect_item.set_sensitive(not up)
            self.disconnect_item.set_sensitive(up)
            return True

    VpnIndicator()
    Gtk.main()
    PYEOF
    chmod +x ~/scripts/vpn/vpn-indicator.py

    cat > ~/.config/systemd/user/vpn-indicator.service <<'EOF'
    [Unit]
    Description=TU Dortmund VPN tray indicator
    [Service]
    ExecStart=%h/scripts/vpn/vpn-indicator.py
    Restart=on-failure
    RestartSec=5
    [Install]
    WantedBy=graphical-session.target
    EOF
    systemctl --user daemon-reload && systemctl --user enable --now vpn-indicator

Install the two icon files as theme icons (created from the official logo SVG
by cropping the viewBox to the TU block mark — `viewBox="0 0 71.06 54.3926"` —
and exporting at 28 px height with inkscape; green is the original `#83b818`,
grey uses `#9e9e9e`):

    mkdir -p ~/.local/share/icons/hicolor/48x48/apps
    cp ~/scripts/vpn/icons/tu-mark-green.png ~/.local/share/icons/hicolor/48x48/apps/tu-vpn-on.png
    cp ~/scripts/vpn/icons/tu-mark-grey.png  ~/.local/share/icons/hicolor/48x48/apps/tu-vpn-off.png

The icon appears in the top bar immediately and at every login: the TU Dortmund
block mark in green when the VPN is connected, grey when not; the menu offers
Connect / Disconnect / Status. If generating the PNGs is not practical
(inkscape missing), replace the two `ICON_*` lines with the theme icon names
`network-vpn-symbolic` / `network-vpn-disconnected-symbolic` instead.

## 5. Plain terminal alternative (no launcher)

    sudo /usr/local/sbin/openconnect --protocol pulse \
        --useragent "Pulse-Secure/22.8.5.41063" stud2.vpn.tu-dortmund.de

Enter your TU username and password when prompted. The VPN runs in that
terminal; Ctrl+C disconnects.

## Usage notes / troubleshooting

- **No 2FA is requested** in the native pulse flow (unlike the web portal).
- **Password saving**: the password is stored in the encrypted GNOME login
  keyring (`secret-tool`, label "TU VPN password"), the username in
  `~/.config/tu-vpn.conf`. If the server rejects the saved password, the stale
  entry is deleted automatically and you are asked again on the next click.
  Standard caveat: while logged in, the unlocked keyring is readable by any
  program running as your user — the same trust level as browser-saved
  passwords. Decline the "Save" dialog to keep the type-it-each-time behavior.
- **"Session limit reached. Choose session to kill:"** — killed or uncleanly
  ended sessions linger on the server (up to ~12 h) and count against a limit
  of ~3. Type one of the listed session IDs and press Enter to kill it, then
  reconnect. To avoid this, disconnect via the toggle (graceful logout)
  instead of killing the process hard.
- **Connection failed notification** — check `~/scripts/vpn/vpn.log` (launcher)
  or run the terminal command from step 5 to see the error directly.
- **Status**: `ip link show tun0` (tunnel interface) or
  `journalctl -t openconnect -f` (live log).
- If the server side changes again (e.g. a new version gate), the fix is
  usually just a newer `Pulse-Secure/...` string — check
  https://gitlab.com/openconnect/openconnect/-/issues/852 for current values.

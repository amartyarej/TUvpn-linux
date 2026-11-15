# TU Dortmund VPN on Linux (Ivanti Connect Secure, students)

Connect to `stud2.vpn.tu-dortmund.de` with OpenConnect in **pulse protocol** mode,
using a current client version string. Works without the official Ivanti client
(which does not exist for Linux) and without the institute's browser-cookie
workaround (broken since the Ivanti upgrade).

The crucial trick: the appliance (ICS 25.1+) **rejects clients that report a
version older than 22.7**. OpenConnect reports an old version by default, so the
connection dies shortly after authentication ("agentd error"). Passing an
up-to-date version string via `--useragent` fixes it. Background:
https://gitlab.com/openconnect/openconnect/-/issues/852.

Tested on Ubuntu 24.04 with OpenConnect v9.21. No 2FA prompt appears in this flow.

## Setup

### 1. Dependencies

    sudo apt install -y build-essential pkg-config libgnutls28-dev \
        libxml2-dev zlib1g-dev zenity libsecret-tools

(`zenity` and `libsecret-tools` are only needed for the optional launcher and
tray icon below; the plain terminal flow works without them.)

### 2. Build OpenConnect 9.21 from source

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

### 3. Passwordless use via sudo

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

(The last command must print `parsed OK`.)

### 4. Optional: one-click launcher

Clone this repo to `~/scripts/vpn` and make the scripts executable:

    chmod +x ~/scripts/vpn/vpn-toggle.sh

`vpn-toggle.sh` asks for your TU username and password (graphical dialogs),
connects in the background, and offers to **save the password in the encrypted
GNOME keyring** — after that, connecting needs no input at all. Clicking while
connected asks for confirmation before disconnecting. Override the server with
the `VPN_SERVER` environment variable if needed.

Desktop entry (shows up as "VPN" in the app grid):

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

### 5. Optional: top-bar status icon

`vpn-indicator.py` shows a tray icon in the GNOME top bar — green when the VPN
is connected, grey when not — with Connect / Disconnect / Status in its menu.
It uses the icon files from [`icons/`](icons/), copying them internally to
per-instance cache paths so the panel never renders a stale icon. Requires
`gir1.2-ayatanaappindicator3-0.1` (installed by default on Ubuntu desktop).

    chmod +x ~/scripts/vpn/vpn-toggle.sh ~/scripts/vpn/vpn-indicator.py
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

If the provided icons don't render on your desktop, replace the icon files in
`resolve_icons()` with the standard theme icons `network-vpn-symbolic` /
`network-vpn-disconnected-symbolic`.

### 6. Plain terminal alternative (no launcher)

    sudo /usr/local/sbin/openconnect --protocol pulse \
        --useragent "Pulse-Secure/22.8.5.41063" stud2.vpn.tu-dortmund.de

Enter your TU username and password when prompted. The VPN runs in that
terminal; Ctrl+C disconnects.

## Troubleshooting

- **No 2FA is requested** in the native pulse flow (unlike the web portal).
- **Password saving**: the password is stored in the encrypted GNOME login
  keyring (`secret-tool`), the username in `~/.config/tu-vpn.conf`. If the
  server rejects the saved password, the stale entry is deleted automatically.
  Standard caveat: while logged in, the unlocked keyring is readable by any
  program running as your user — the same trust level as browser-saved
  passwords. Decline the "Save" dialog to keep the type-it-each-time behavior.
- **"Session limit reached. Choose session to kill:"** — killed or uncleanly
  ended sessions linger on the server (up to ~12 h) and count against a limit
  of ~3. Type one of the listed session IDs and press Enter to kill it, then
  reconnect. To avoid this, disconnect via the toggle (graceful logout)
  instead of killing the process hard.
- **Connection failed** — check `~/scripts/vpn/vpn.log` (launcher), or run the
  terminal command from step 6 to see the error directly. Live log:
  `journalctl -t openconnect -f`.
- If the server side changes again (e.g. a new version gate), the fix is
  usually just a newer `Pulse-Secure/...` string — check
  https://gitlab.com/openconnect/openconnect/-/issues/852 for current values.

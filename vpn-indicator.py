#!/usr/bin/env python3
"""TU Dortmund VPN tray indicator.

Shows a top-bar icon that switches with the VPN state and offers
Connect / Disconnect (via vpn-toggle.sh) and a status dialog.
"""
import gi
import os
import subprocess

gi.require_version("AyatanaAppIndicator3", "0.1")
gi.require_version("Gtk", "3.0")
from gi.repository import AyatanaAppIndicator3, Gtk, GLib

TOGGLE = os.path.expanduser("~/scripts/vpn/vpn-toggle.sh")
ICON_ON = os.path.expanduser("~/scripts/vpn/icons/tu-mark-green.png")
ICON_OFF = os.path.expanduser("~/scripts/vpn/icons/tu-mark-grey.png")
PGREP = ["pgrep", "-f", "openconnect --protocol pulse"]


def vpn_running():
    # Authoritative check: the tunnel interface exists (works regardless of
    # how openconnect was started; avoids process-name matching pitfalls).
    return subprocess.run(["ip", "link", "show", "tun0"],
                          capture_output=True).returncode == 0


def tunnel_ip():
    out = subprocess.run(["ip", "-4", "addr", "show", "tun0"],
                         capture_output=True, text=True).stdout
    for tok in out.split():
        if tok.startswith("inet "):
            pass
    for line in out.splitlines():
        if "inet " in line:
            return line.split()[1].split("/")[0]
    return None


class VpnIndicator:
    def __init__(self):
        self._last_up = None
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

        self.sep = Gtk.SeparatorMenuItem()
        self.sep.show()
        self.menu.append(self.sep)

        self.connect_item = Gtk.MenuItem(label="Connect")
        self.connect_item.connect("activate", self.on_connect)
        self.connect_item.show()
        self.menu.append(self.connect_item)

        self.disconnect_item = Gtk.MenuItem(label="Disconnect…")
        self.disconnect_item.connect("activate", self.on_disconnect)
        self.disconnect_item.show()
        self.menu.append(self.disconnect_item)

        self.status_item = Gtk.MenuItem(label="Status…")
        self.status_item.connect("activate", self.on_status)
        self.status_item.show()
        self.menu.append(self.status_item)

        self.ind.set_menu(self.menu)
        self.tick()
        GLib.timeout_add_seconds(3, self.tick)

    # --- actions -----------------------------------------------------------
    def on_connect(self, _):
        subprocess.Popen([TOGGLE])

    def on_disconnect(self, _):
        subprocess.Popen([TOGGLE])

    def on_status(self, _):
        if vpn_running():
            ip = tunnel_ip() or "unknown"
            text = (f"VPN connected to stud2.vpn.tu-dortmund.de\n"
                    f"Tunnel IP: {ip}")
        else:
            text = "VPN is not connected."
        subprocess.Popen(["zenity", "--info", "--title=VPN", "--timeout=8",
                          f"--text={text}"])

    # --- state polling -----------------------------------------------------
    def tick(self):
        up = vpn_running()
        if up != self._last_up:                    # update icon only on change
            self.ind.set_icon_full(ICON_ON if up else ICON_OFF, "TU Dortmund VPN")
            self._last_up = up
        if up:
            ip = tunnel_ip() or "…"
            self.state_item.set_label(f"VPN: connected ({ip})")
        else:
            self.state_item.set_label("VPN: not connected")
        self.connect_item.set_sensitive(not up)
        self.disconnect_item.set_sensitive(up)
        return True  # keep the timer


def main():
    VpnIndicator()
    Gtk.main()


if __name__ == "__main__":
    main()

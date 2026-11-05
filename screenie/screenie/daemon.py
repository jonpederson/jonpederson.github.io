"""Background watcher: starts the screensaver after N minutes without input.

Mutter's IdleMonitor reports time since the last real keyboard/mouse input and
is not affected by idle inhibitors, so this works even while apps keep the
session awake.
"""

import fcntl
import os
import subprocess
import sys

from gi.repository import Gio, GLib

from . import config

POLL_SECONDS = 2


class Daemon:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        self.cfg = config.load()
        self.cfg_mtime = config.mtime()
        self.child = None
        self.fired = False  # already triggered during the current idle stretch

    def _call(self, name, path, iface, method):
        try:
            return self.bus.call_sync(name, path, iface, method, None, None,
                                      Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
        except GLib.Error:
            return None

    def idle_ms(self):
        return self._call("org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
                          "org.gnome.Mutter.IdleMonitor", "GetIdletime")

    def screen_locked(self):
        return bool(self._call("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
                               "org.gnome.ScreenSaver", "GetActive"))

    def tick(self):
        m = config.mtime()
        if m != self.cfg_mtime:
            self.cfg, self.cfg_mtime = config.load(), m

        if self.child and self.child.poll() is not None:
            self.child = None

        idle = self.idle_ms()
        if idle is None:
            return True
        threshold = max(1, int(self.cfg["idle_minutes"])) * 60_000
        if idle < threshold:
            self.fired = False
        elif self.cfg["enabled"] and not self.fired and not self.child and not self.screen_locked():
            self.fired = True
            self.child = subprocess.Popen([sys.executable, "-m", "screenie", "show"],
                                          cwd=os.path.dirname(os.path.dirname(__file__)))
        return True

    def run(self):
        GLib.timeout_add_seconds(POLL_SECONDS, self.tick)
        GLib.MainLoop().run()


def main():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    lock = open(os.path.join(runtime, "screenie-daemon.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("screenie daemon is already running", file=sys.stderr)
        return 0
    Daemon().run()
    return 0

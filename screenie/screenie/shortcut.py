"""Registers the global keyboard shortcut as a GNOME custom keybinding."""

import shutil
from pathlib import Path

from gi.repository import Gio

MEDIA_KEYS = "org.gnome.settings-daemon.plugins.media-keys"
CUSTOM_SCHEMA = MEDIA_KEYS + ".custom-keybinding"
PATH = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/screenie/"


def _command():
    exe = shutil.which("screenie") or str(Path.home() / ".local/bin/screenie")
    return f"{exe} show"


def apply(binding):
    """Set the shortcut; an empty binding removes it."""
    if not binding:
        remove()
        return
    custom = Gio.Settings.new_with_path(CUSTOM_SCHEMA, PATH)
    custom.set_string("name", "Screenie screensaver")
    custom.set_string("command", _command())
    custom.set_string("binding", binding)
    media = Gio.Settings.new(MEDIA_KEYS)
    paths = list(media.get_strv("custom-keybindings"))
    if PATH not in paths:
        media.set_strv("custom-keybindings", paths + [PATH])
    Gio.Settings.sync()


def remove():
    media = Gio.Settings.new(MEDIA_KEYS)
    paths = [p for p in media.get_strv("custom-keybindings") if p != PATH]
    media.set_strv("custom-keybindings", paths)
    custom = Gio.Settings.new_with_path(CUSTOM_SCHEMA, PATH)
    for key in ("name", "command", "binding"):
        custom.reset(key)
    Gio.Settings.sync()

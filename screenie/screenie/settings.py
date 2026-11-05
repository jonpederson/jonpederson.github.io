"""Settings window (libadwaita)."""

import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, Gtk

from . import config, shortcut
from .hud_data import parse_coords

APP_ID = "local.screenie.Settings"
PKG_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ShortcutDialog(Adw.Dialog):
    """Captures a new key combination."""

    def __init__(self, on_done):
        super().__init__(title="Set Shortcut", content_width=420)
        self.on_done = on_done
        page = Adw.StatusPage(
            icon_name="preferences-desktop-keyboard-shortcuts-symbolic",
            title="Press a key combination",
            description="Esc to cancel · Backspace to disable the shortcut",
        )
        toolbar = Adw.ToolbarView(content=page)
        toolbar.add_top_bar(Adw.HeaderBar())
        self.set_child(toolbar)
        keys = Gtk.EventControllerKey(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)

    def _on_key(self, _ctrl, keyval, _code, state):
        mods = state & Gtk.accelerator_get_default_mod_mask()
        if not mods and keyval == Gdk.KEY_Escape:
            self.close()
            return True
        if not mods and keyval == Gdk.KEY_BackSpace:
            self.on_done("")
            self.close()
            return True
        if Gdk.ModifierType.SHIFT_MASK & mods and not (mods & ~Gdk.ModifierType.SHIFT_MASK):
            return True  # Shift alone isn't a safe global modifier
        if not mods or not Gtk.accelerator_valid(Gdk.keyval_to_lower(keyval), mods):
            return True  # still waiting for a real combination (e.g. only modifiers so far)
        self.on_done(Gtk.accelerator_name(Gdk.keyval_to_lower(keyval), mods))
        self.close()
        return True


class SettingsWindow(Adw.PreferencesWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Screenie", default_width=560, default_height=760,
                         search_enabled=False)
        self.cfg = config.load()
        page = Adw.PreferencesPage()
        self.add(page)

        # --- Activation
        act = Adw.PreferencesGroup(
            title="Activation",
            description="Screenie watches real keyboard and mouse activity, so it starts even "
                        "while other apps keep the computer awake.")
        page.add(act)

        enabled = Adw.SwitchRow(title="Start when idle", active=self.cfg["enabled"])
        enabled.connect("notify::active", lambda r, _: self._set("enabled", r.get_active()))
        act.add(enabled)

        idle = Adw.SpinRow.new_with_range(1, 240, 1)
        idle.set_title("Idle time")
        idle.set_subtitle("Minutes without keyboard or mouse input")
        idle.set_value(self.cfg["idle_minutes"])
        idle.connect("notify::value", lambda r, _: self._set("idle_minutes", int(r.get_value())))
        enabled.bind_property("active", idle, "sensitive", 2)  # SYNC_CREATE
        act.add(idle)

        self.shortcut_row = Adw.ActionRow(title="Keyboard shortcut",
                                          subtitle="Start the screensaver right away")
        self.shortcut_label = Gtk.ShortcutLabel(disabled_text="Disabled", valign=Gtk.Align.CENTER)
        self.shortcut_row.add_suffix(self.shortcut_label)
        change = Gtk.Button(label="Change", valign=Gtk.Align.CENTER)
        change.connect("clicked", self._change_shortcut)
        self.shortcut_row.add_suffix(change)
        self.shortcut_row.set_activatable_widget(change)
        self._show_shortcut()
        act.add(self.shortcut_row)

        # --- Appearance
        look = Adw.PreferencesGroup(title="Appearance")
        page.add(look)

        keys = list(config.STYLES)
        style = Adw.ComboRow(title="Style", model=Gtk.StringList.new(list(config.STYLES.values())))
        style.set_selected(keys.index(self.cfg["style"]))
        style.connect("notify::selected", lambda r, _: self._set("style", keys[r.get_selected()]))
        look.add(style)

        clock = Adw.SwitchRow(title="Show clock", active=self.cfg["show_clock"])
        clock.connect("notify::active", lambda r, _: self._set("show_clock", r.get_active()))
        look.add(clock)

        preview = Adw.ButtonRow(title="Preview", start_icon_name="media-playback-start-symbolic")
        preview.connect("activated", lambda *_: subprocess.Popen(
            [sys.executable, "-m", "screenie", "show"], cwd=PKG_ROOT))
        prev_group = Adw.PreferencesGroup()
        prev_group.add(preview)
        page.add(prev_group)

        # --- Agents style
        ag = Adw.PreferencesGroup(
            title="Agents Style",
            description="Mission control for the AI agents running on this computer.")
        page.add(ag)
        details = Adw.SwitchRow(
            title="Show task titles and file names",
            subtitle="Off shows only anonymous stats. Prompts, code and commands are never shown.",
            active=self.cfg["agents_details"])
        details.connect("notify::active", lambda r, _: self._set("agents_details", r.get_active()))
        ag.add(details)

        # --- HUD style
        hud = Adw.PreferencesGroup(
            title="HUD Style",
            description="Live data from Open-Meteo, USGS, NASA/JPL, NOAA, ORNL, WisDOT and wheretheiss.at. "
                        "Your location is estimated from your IP address unless you enter it here.")
        page.add(hud)

        loc = Adw.EntryRow(title="Exact location (latitude, longitude)", show_apply_button=True,
                           text=self.cfg["hud_location"])
        loc.connect("apply", self._apply_location)
        hud.add(loc)

        unit_keys = ["auto", "imperial", "metric"]
        units = Adw.ComboRow(title="Units",
                             model=Gtk.StringList.new(["Automatic", "US (°F, mph, miles)", "Metric"]))
        units.set_selected(unit_keys.index(self.cfg["hud_units"]) if self.cfg["hud_units"] in unit_keys else 0)
        units.connect("notify::selected", lambda r, _: self._set("hud_units", unit_keys[r.get_selected()]))
        hud.add(units)

        # --- Privacy
        sec = Adw.PreferencesGroup(title="Privacy")
        page.add(sec)
        lock = Adw.SwitchRow(
            title="Require password to dismiss",
            subtitle="Shows the GNOME lock screen when you return. Your apps keep running.",
            active=self.cfg["lock_on_dismiss"])
        lock.connect("notify::active", lambda r, _: self._set("lock_on_dismiss", r.get_active()))
        sec.add(lock)

    def _set(self, key, value):
        self.cfg[key] = value
        config.save(self.cfg)

    def _apply_location(self, row):
        text = row.get_text().strip()
        if text and parse_coords(text) is None:
            self.add_toast(Adw.Toast(title="Enter coordinates like 45.2041, -91.5582"))
            return
        self._set("hud_location", text)

    def _show_shortcut(self):
        self.shortcut_label.set_accelerator(self.cfg["shortcut"] or "")

    def _change_shortcut(self, _btn):
        def done(accel):
            try:
                shortcut.apply(accel)
            except Exception as e:  # noqa: BLE001 - surface any gsettings failure to the user
                self.add_toast(Adw.Toast(title=f"Couldn't set shortcut: {e}"))
                return
            self._set("shortcut", accel)
            self._show_shortcut()
        ShortcutDialog(done).present(self)


class SettingsApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        win = self.get_active_window() or SettingsWindow(self)
        win.present()


def main():
    return SettingsApp().run([sys.argv[0]])

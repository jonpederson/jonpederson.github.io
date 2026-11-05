"""Settings storage shared by the daemon, the screensaver and the settings app."""

import json
import os
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "screenie"
CONFIG_FILE = CONFIG_DIR / "config.json"

STYLES = {
    "aurora": "Aurora",
    "starfield": "Starfield",
    "farm": "Farm",
    "hud": "HUD",
    "agents": "Agents",
    "black": "Black",
}

DEFAULTS = {
    "enabled": True,  # start automatically after idle_minutes of no input
    "idle_minutes": 5,
    "style": "aurora",
    "show_clock": True,
    "lock_on_dismiss": False,  # hand off to the GNOME lock screen when dismissed
    "shortcut": "<Control><Super>s",
    # HUD style
    "hud_location": "",  # "lat, lon"; blank = estimate from IP address
    "hud_units": "auto",  # auto | imperial | metric
    # Agents style
    "agents_details": True,  # show session titles, project and file names
}


def load():
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(CONFIG_FILE.read_text()))
    except (OSError, ValueError):
        pass
    if cfg["style"] not in STYLES:
        cfg["style"] = DEFAULTS["style"]
    return cfg


def save(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n")
    tmp.replace(CONFIG_FILE)


def mtime():
    try:
        return CONFIG_FILE.stat().st_mtime
    except OSError:
        return 0.0

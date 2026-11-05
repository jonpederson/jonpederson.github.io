"""screenie — a screensaver for GNOME that ignores idle inhibitors.

Usage:
  screenie                 open settings
  screenie show            start the screensaver now
  screenie daemon          run the idle watcher (started automatically at login)
  screenie apply-shortcut  register the keyboard shortcut from the config
  screenie remove-shortcut unregister the keyboard shortcut
"""

import sys

import gi

gi.require_version("Gio", "2.0")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "settings"
    if cmd == "show":
        from . import saver
        return saver.main()
    if cmd == "daemon":
        from . import daemon
        return daemon.main()
    if cmd == "settings":
        from . import settings
        return settings.main()
    if cmd in ("apply-shortcut", "remove-shortcut"):
        from . import config, shortcut
        if cmd == "apply-shortcut":
            shortcut.apply(config.load()["shortcut"])
        else:
            shortcut.remove()
        return 0
    print(__doc__)
    return 0 if cmd in ("-h", "--help", "help") else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

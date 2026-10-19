#!/usr/bin/env python3
"""Starts the ThatPet Ollama Extension at macOS login (LaunchAgents).

  python3 autostart.py install     copy the bridge, this script and the menu bar icon to
                                   ~/Library/Application Support/OllamaThatPetBridge and
                                   start them now and at every login; run it again from
                                   the project folder after a change to update the copies
  python3 autostart.py uninstall   stop everything and remove what install created
  python3 autostart.py stop        turn the bridge off; it stays off after a restart
  python3 autostart.py start       turn the bridge back on (now and at every login)
  python3 autostart.py quit        stop the bridge and the menu bar icon until next login
  python3 autostart.py status      show whether it is running and the last log lines
  python3 autostart.py state       print only running/stopped/disabled/not-installed

Nothing in Ollama or ThatPet is modified. The copies live outside
Documents/Desktop/Downloads because launchd cannot read those folders.
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

LABEL = "local.ollama-thatpet-bridge"
HOME = Path.home()
SOURCE = Path(__file__).resolve().parent / "ollama_thatpet_bridge.py"
INSTALL_DIR = HOME / "Library/Application Support/OllamaThatPetBridge"
SCRIPT = INSTALL_DIR / SOURCE.name
# Copy of this script, so you can uninstall even without the project folder.
SELF_COPY = INSTALL_DIR / "autostart.py"
PLIST = HOME / "Library/LaunchAgents" / f"{LABEL}.plist"
LOG = HOME / "Library/Logs/ollama-thatpet-bridge.log"
SERVICE = f"gui/{os.getuid()}/{LABEL}"
# Menu bar icon (built with build_menu_app.sh).
MENU_LABEL = f"{LABEL}.menu"
MENU_SERVICE = f"gui/{os.getuid()}/{MENU_LABEL}"
MENU_PLIST = HOME / "Library/LaunchAgents" / f"{MENU_LABEL}.plist"
MENU_SOURCE = SOURCE.parent / "ThatPet Ollama Extension.app"
MENU_APP = INSTALL_DIR / MENU_SOURCE.name
# Earlier name of the icon app, removed on install.
LEGACY_MENU_APP = INSTALL_DIR / "Bridge Ollama-ThatPet.app"
# System Python first (Homebrew updates don't change it; the bridge is tested
# with 3.9), then Homebrew's.
PYTHONS = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]


def launchctl(*args):
    return subprocess.run(["launchctl", *args], capture_output=True, text=True)


def loaded(service=SERVICE):
    return launchctl("print", service).returncode == 0


def bootout(service=SERVICE):
    if not loaded(service):
        return
    launchctl("bootout", service)
    for _ in range(50):  # bootout stops the service asynchronously
        if not loaded(service):
            return
        time.sleep(0.1)
    sys.exit("launchctl did not stop the service within 5 seconds; try again.")


def disabled():
    """True if the bridge was turned off with `stop` (persistent launchd override)."""
    out = launchctl("print-disabled", f"gui/{os.getuid()}").stdout
    match = re.search(rf'"{re.escape(LABEL)}" => (\w+)', out)
    return bool(match) and match.group(1) in ("disabled", "true")


def current_state():
    if loaded():
        return "running"
    if not PLIST.exists():
        return "not-installed"
    return "disabled" if disabled() else "stopped"


def bootstrap(service=SERVICE, plist=PLIST):
    launchctl("enable", service)  # undo an earlier `stop`
    if loaded(service):
        return
    result = launchctl("bootstrap", f"gui/{os.getuid()}", str(plist))
    if result.returncode != 0:
        sys.exit(f"launchctl bootstrap failed: {(result.stderr or result.stdout).strip()}")


def manual_bridges():
    """Bridges started by hand (Terminal or tests): they would double the events."""
    out = subprocess.run(["pgrep", "-fl", SOURCE.name], capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if str(SCRIPT) not in line]


def pick_python():
    for python in PYTHONS:
        if not os.access(python, os.X_OK):
            continue
        check = subprocess.run([python, "-I", str(SOURCE), "--help"], capture_output=True)
        if check.returncode == 0:
            return python
    sys.exit("No usable Python 3 found in: " + ", ".join(PYTHONS))


def install():
    if not SOURCE.is_file():
        sys.exit(f"Bridge not found next to this script: {SOURCE}")
    others = manual_bridges()
    if others:
        pids = ", ".join(line.split(" ", 1)[0] for line in others)
        sys.exit(f"A bridge started by hand is already running (pid {pids}): stop it first "
                 "(Ctrl+C in its Terminal), otherwise ThatPet would get every event twice.")
    python = pick_python()
    bootout()  # reinstall: stop the previous version
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    if SOURCE != SCRIPT:  # not when re-running the installed copy
        shutil.copy2(SOURCE, SCRIPT)
        shutil.copy2(Path(__file__).resolve(), SELF_COPY)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(PLIST, "wb") as f:
        plistlib.dump({
            "Label": LABEL,
            "ProgramArguments": [python, "-I", str(SCRIPT), "--wait-for-lock"],
            "RunAtLoad": True,
            "KeepAlive": True,         # restart the bridge if it exits
            "ThrottleInterval": 30,    # ...but not more than once every 30 s
            "StandardOutPath": str(LOG),
            "StandardErrorPath": str(LOG),
        }, f)
    bootstrap()
    print(f"Installed and started with {python}.")
    print(f"  bridge: {SCRIPT}")
    print(f"  agent:  {PLIST}")
    print(f"  log:    {LOG}")
    install_menu()


def install_menu():
    if MENU_SOURCE.is_dir() and MENU_SOURCE != MENU_APP:
        bootout(MENU_SERVICE)  # close the old icon before replacing it
        for old in (MENU_APP, LEGACY_MENU_APP):
            if old.exists():
                shutil.rmtree(old)
        shutil.copytree(MENU_SOURCE, MENU_APP, symlinks=True)
    if not MENU_APP.is_dir():
        print("Menu bar icon not found: run ./build_menu_app.sh, then install again.")
        return
    with open(MENU_PLIST, "wb") as f:
        plistlib.dump({
            "Label": MENU_LABEL,
            "ProgramArguments": [str(MENU_APP / "Contents/MacOS/BridgeMenu")],
            "RunAtLoad": True,
            "KeepAlive": False,  # after Quit it comes back at the next login
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        }, f)
    bootstrap(MENU_SERVICE, MENU_PLIST)
    print(f"  icon:   {MENU_APP}")


def uninstall():
    bootout()
    bootout(MENU_SERVICE)
    for app in (MENU_APP, LEGACY_MENU_APP):
        if app.exists():
            shutil.rmtree(app)
    removed = [p for p in (PLIST, MENU_PLIST, SCRIPT, SELF_COPY) if p.exists()]
    for path in removed:
        path.unlink()
    for state in ("bridge.lock", "health.json", "health.json.tmp"):  # written by the bridge
        if (INSTALL_DIR / state).exists():
            (INSTALL_DIR / state).unlink()
    if INSTALL_DIR.is_dir() and not any(INSTALL_DIR.iterdir()):
        INSTALL_DIR.rmdir()
    print("Autostart removed." if removed else "It was not installed.")
    if LOG.exists():
        print(f"The log is still at {LOG} (you can delete it by hand).")


def start():
    if not PLIST.exists():
        sys.exit("The bridge is not installed: run `autostart.py install` first.")
    bootstrap()
    print("Bridge turned on.")


def stop():
    if not PLIST.exists():
        sys.exit("The bridge is not installed.")
    launchctl("disable", SERVICE)  # don't start at login until `start`
    bootout()
    print("Bridge turned off: it stays off after a restart until you turn it back on.")


def quit_until_login():
    bootout()
    bootout(MENU_SERVICE)
    print("Bridge and menu bar icon stopped until the next login.")


def status():
    result = launchctl("print", SERVICE)
    if result.returncode != 0:
        print({"not-installed": "Autostart: not installed.",
               "disabled": "Bridge turned off (turn it back on with `autostart.py start`).",
               }.get(current_state(), "Autostart: installed but not loaded (it starts at the next login)."))
    else:
        info = dict(re.findall(r"^\s*(state|pid|last exit code) = (.+)$", result.stdout, re.M))
        print(f"Autostart: {info.get('state', '?')}"
              + (f", pid {info['pid']}" if "pid" in info else "")
              + f" (last exit: {info.get('last exit code', '?')})")
    menu = re.search(r"^\s*pid = (\d+)", launchctl("print", MENU_SERVICE).stdout, re.M)
    print("Menu bar icon: " + (f"open (pid {menu.group(1)})" if menu else
          "not open" if MENU_PLIST.exists() else "not installed"))
    if LOG.exists():
        print(f"--- last lines of {LOG}")
        print("\n".join(LOG.read_text(errors="replace").splitlines()[-10:]))


if __name__ == "__main__":
    commands = {"install": install, "uninstall": uninstall, "start": start, "stop": stop,
                "quit": quit_until_login, "status": status,
                "state": lambda: print(current_state())}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]]()

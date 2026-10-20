#!/usr/bin/env python3
"""Ollama Desktop (macOS) -> ThatPet bridge, version 3.

How it works:
- TURN START: a new row with a recent `created_at` appears in the `messages`
  table of the Ollama Desktop database (opened read-only). Ollama sometimes
  rewrites a whole chat with new ids but the original dates: those rows are
  ignored.
- TURN END: Ollama Desktop writes a `POST /api/v1/chat/{id}` line to
  ~/.ollama/logs/app.log the moment the reply stream finishes. If a
  `chat stream error` line comes right before it, the turn was stopped by the
  user (`context canceled`) or failed.
- TOOLS: when the model calls a tool (e.g. web_search) Ollama saves a row in
  `tool_calls`, then a `tool` message with the result. The pet works from the
  call until the model starts writing again, so it also covers the minutes
  spent reading the result. ThatPet picks the bubble from the tool name:
  web_search -> "Browsing the web…". Each call counts once, even when Ollama
  rewrites the tool_calls rows.
- Without app.log the bridge falls back to the v2 inactivity timeout.

Events sent to ThatPet's helper (same mapping as the Hermes plugin that ships
with ThatPet, verified with direct tests):
  SessionStart -> idle            UserPromptSubmit -> thinking
  PreToolUse   -> working         Stop             -> celebrating
  StopFailure  -> error
SessionEnd is NEVER sent: it is verified to make ThatPet quit.

Only one bridge runs at a time (lock file). A small health.json tells the menu
bar icon if reply ends stop being detected. The log keeps only its last part.

Conversation text is never read, stored or printed.
"""

import argparse
import fcntl
import json
import os
import re
import signal
import sqlite3
import stat
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path.home()
DEFAULT_DB = HOME / "Library/Application Support/Ollama/db.sqlite"
DEFAULT_LOG = HOME / ".ollama/logs/app.log"
DEFAULT_PET = Path("/Applications/ThatPet.app/Contents/MacOS/ThatPet")
PET_PID_FILE = HOME / "Library/Application Support/ThatPet/run/pet.pid"
# Lock file and health.json live next to the installed copy.
DEFAULT_STATE_DIR = HOME / "Library/Application Support/OllamaThatPetBridge"
# The log (stdout, opened by launchd) is cut back to its last KEEP_LOG bytes past MAX_LOG.
MAX_LOG, KEEP_LOG = 1_000_000, 200_000
# Fixed id: ThatPet keeps one file per session in run/sessions, and with a new
# id on every bridge start (v2) those files would pile up.
SESSION_ID = "ollama-desktop"

# app.log line written when a chat stream ends.
STREAM_END = re.compile(r'http\.pattern="POST /api/v1/chat/\{id\}"\s+http\.status=(\d+)')
STREAM_ERROR = 'msg="chat stream error"'

# A row counts as a new message only if it was created less than RECENT seconds ago.
RECENT = 120
# ThatPet drops a state after 60 s without events (Brain.Config.stateTimeout), while
# Ollama phases last minutes: repeat the current event this often during a turn.
HEARTBEAT = 20
# created_at formats seen: "2026-10-19 22:55:06.657+02:00" (Ollama, 1-9
# decimals) and "2026-10-19 20:55:06" (SQLite CURRENT_TIMESTAMP, UTC).
TIMESTAMP = re.compile(r"(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)(?:\.(\d+))?\s*(Z|[+-]\d\d:?\d\d)?")

# Turn outcome -> (ThatPet event, description for the log)
OUTCOMES = {
    "completed": ("Stop", "reply completed"),
    "canceled": ("SessionStart", "stopped by the user"),  # like the Hermes plugin: back to idle
    "failed": ("StopFailure", "Ollama error"),
    "presumed": ("Stop", "no new text"),                   # only without app.log
    "stalled": ("SessionStart", "no end signal"),
    "stopped": ("SessionStart", "bridge stopped"),
}


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def parse_time(text):
    """created_at -> epoch seconds, or None. Hand-written to work on Python 3.9."""
    match = TIMESTAMP.match(text or "")
    if not match:
        return None
    day, clock, fraction, zone = match.groups()
    moment = datetime.strptime(f"{day} {clock}", "%Y-%m-%d %H:%M:%S")
    if fraction:
        moment += timedelta(microseconds=int(fraction[:6].ljust(6, "0")))
    offset = timedelta(0)
    if zone and zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        offset = sign * timedelta(hours=int(zone[1:3]), minutes=int(zone[-2:]))
    return (moment - offset - datetime(1970, 1, 1)).total_seconds()


def tool_label(name):
    """What the menu shows while a tool runs (ThatPet uses the same web tool names)."""
    lower = (name or "").lower()
    if lower.startswith("browser_") or lower in ("websearch", "webfetch", "web_search", "web_fetch",
                                                  "web_extract", "search_web", "read_url_content"):
        return "Browsing the web"
    return f"Using {name or 'a tool'}"


def is_fresh(created_at, since):
    """True for rows created during the current turn (rewritten rows keep old dates)."""
    ts = parse_time(created_at)
    return ts is not None and ts >= since - 1


def acquire_lock(path, wait):
    """Only one bridge at a time. Returns the open lock file, or None if another one holds it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(path, "a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        if not wait:
            handle.seek(0)
            other = handle.read().strip() or "?"
            handle.close()
            log(f"Another bridge is already running (pid {other}): turn it off first "
                "(menu bar icon or `autostart.py stop`), otherwise ThatPet gets every event twice.")
            return None
        log("Another bridge is running: waiting until it stops")
        fcntl.flock(handle, fcntl.LOCK_EX)
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()))
    handle.flush()
    return handle


def trim_log():
    """If stdout is a log file opened for appending (launchd does this), keep only its end."""
    try:
        sys.stdout.flush()
        st = os.fstat(1)
        if (not stat.S_ISREG(st.st_mode) or st.st_size <= MAX_LOG
                or not fcntl.fcntl(1, fcntl.F_GETFL) & os.O_APPEND):
            return
        path = os.fsdecode(fcntl.fcntl(1, fcntl.F_GETPATH, bytes(1024)).split(b"\0", 1)[0])
        with open(path, "r+b") as f:
            f.seek(-KEEP_LOG, os.SEEK_END)
            tail = f.read()
            tail = tail[tail.find(b"\n") + 1:]  # start at a whole line
            f.seek(0)
            f.write(tail)
            f.truncate()
        log(f"Log trimmed to its last {len(tail) // 1000} KB")
    except (OSError, ValueError, AttributeError):
        pass


class Health:
    """Small status file read by the menu bar icon (no chat content)."""

    def __init__(self, path):
        self.path = path
        self.data = {}

    def update(self, **changes):
        data = {**self.data, **changes}
        if data == self.data:
            return
        self.data = data
        try:
            tmp = self.path.with_name(self.path.name + ".tmp")
            tmp.write_text(json.dumps(data))
            os.replace(tmp, self.path)
        except OSError:
            pass


class Pet:
    """Sends events to ThatPet's official helper, never to its socket."""

    def __init__(self, helper):
        self.helper = helper
        self.pid = self.running_pid()
        self.session_pid = None  # ThatPet process that already got SessionStart
        self.next_check = 0.0

    @staticmethod
    def running_pid():
        """PID of the ThatPet app read from run/pet.pid, or None (diagnostics only)."""
        try:
            pid = int(PET_PID_FILE.read_text().strip())
            os.kill(pid, 0)
            return pid
        except (OSError, ValueError):
            return None

    def watch(self, now):
        if now < self.next_check:
            return
        self.next_check = now + 2
        pid = self.running_pid()
        if pid != self.pid:
            log("WARNING: ThatPet disappeared/quit!" if pid is None
                else f"ThatPet running (pid {pid})")
            self.pid = pid

    def emit(self, event, tool=None, quiet=False):
        payload = {"hook_event_name": event, "session_id": SESSION_ID}
        if tool:
            payload["tool_name"] = tool[:64]
        try:
            p = subprocess.run(
                [str(self.helper), "hook", "--provider", "hermes"],
                input=json.dumps(payload).encode("utf-8"),
                capture_output=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            log(f"ERROR hook {event}: {error}")
            return False
        if p.returncode != 0:
            reason = p.stderr.decode("utf-8", errors="replace").strip()[:200]
            log(f"ERROR hook {event}: exit code {p.returncode}; {reason}")
            return False
        if not quiet:
            log(f"Hook sent: {event}" + ("" if self.pid else " (ThatPet does not seem to be open)"))
        return True

    def prompt(self):
        # One session per ThatPet process: if the app was reopened,
        # the new instance gets SessionStart again.
        pid = self.running_pid()
        if pid is None or pid != self.session_pid:
            self.emit("SessionStart")
            self.session_pid = pid
        self.emit("UserPromptSubmit")


class OllamaDB:
    """Ollama Desktop database, read-only; queried only when its files change."""

    def __init__(self, path):
        self.path = path
        self.files = (path, path.with_name(path.name + "-wal"))
        self.conn = None
        self.stamp = None

    def changed(self):
        stamp = []
        for f in self.files:
            try:
                st = f.stat()
                stamp.append((st.st_mtime_ns, st.st_size))
            except OSError:
                stamp.append(None)
        stamp = tuple(stamp)
        if stamp == self.stamp:
            return False
        self.stamp = stamp
        return True

    def query(self, sql, params=()):
        try:
            if self.conn is None:
                # Read-only but WITHOUT immutable=1: it must see WAL updates.
                uri = self.path.resolve().as_uri() + "?mode=ro"
                self.conn = sqlite3.connect(uri, uri=True, timeout=1)
                self.conn.execute("PRAGMA query_only = ON")
            return self.conn.execute(sql, params).fetchall()
        except sqlite3.Error:
            self.close()
            self.stamp = None  # try again on the next round
            raise

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def max_id(self):
        return self.query("SELECT coalesce(max(id), 0) FROM messages")[0][0]

    def rows_after(self, last_id):
        return self.query(
            "SELECT id, chat_id, role, created_at FROM messages WHERE id > ? ORDER BY id",
            (last_id,))

    def max_tool_call_id(self):
        """Highest tool_calls id, or None if this Ollama version has no such table."""
        try:
            return self.query("SELECT coalesce(max(id), 0) FROM tool_calls")[0][0]
        except sqlite3.OperationalError:
            return None

    def tool_calls_after(self, last_id):
        return self.query(
            "SELECT tc.id, tc.function_name, m.chat_id, m.created_at FROM tool_calls tc "
            "JOIN messages m ON m.id = tc.message_id WHERE tc.id > ? ORDER BY tc.id",
            (last_id,))

    def latest_reply(self, chat_id):
        """(created_at in epoch seconds, text length) of the chat's latest assistant message."""
        row = self.query(
            "SELECT created_at, length(coalesce(content,'')) + length(coalesce(thinking,'')) "
            "FROM messages WHERE role = 'assistant' AND chat_id = ? "
            "ORDER BY id DESC LIMIT 1",
            (chat_id,),
        )
        if not row or parse_time(row[0][0]) is None:
            return None
        return parse_time(row[0][0]), row[0][1]


class LogFollower:
    """Reads only the new lines of app.log; handles rotation and truncation."""

    def __init__(self, path):
        self.path = path
        self.inode = None
        self.pos = 0
        self.partial = b""
        try:
            st = path.stat()
            self.inode, self.pos = st.st_ino, st.st_size  # skip the history
        except OSError:
            pass

    @property
    def available(self):
        return self.inode is not None

    def new_lines(self):
        try:
            st = self.path.stat()
        except OSError:
            self.inode = None
            return []
        if st.st_ino != self.inode or st.st_size < self.pos:
            # Ollama restarted (log rotated) or file truncated: read from the start.
            self.inode, self.pos, self.partial = st.st_ino, 0, b""
        if st.st_size == self.pos:
            return []
        with open(self.path, "rb") as f:
            f.seek(self.pos)
            data = f.read(st.st_size - self.pos)
        self.pos += len(data)
        lines = (self.partial + data).split(b"\n")
        self.partial = lines.pop()
        return [line.decode("utf-8", errors="replace") for line in lines]


def selftest(pet):
    """Tests only the ThatPet side, without Ollama."""
    log("ThatPet self-test: watch the character on screen.")
    for event, wait, expected in [
        ("SessionStart", 3, "idle"),
        ("UserPromptSubmit", 5, "Thinking"),
        ("Stop", 8, "Done, then idle again"),
    ]:
        pet.emit(event)
        log(f"  expected: {expected}")
        time.sleep(wait)
        if pet.running_pid() is None:
            log(f"FAILED: ThatPet quit after {event}")
            return 1
    log("OK: ThatPet stayed open after every event.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Ollama Desktop -> ThatPet bridge (v3)")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG,
                        help="Ollama Desktop app.log, used to detect when replies end")
    parser.add_argument("--pet", type=Path, default=DEFAULT_PET)
    parser.add_argument("--poll", type=float, default=0.5,
                        help="Check interval in seconds (default: 0.5)")
    parser.add_argument("--idle", type=float, default=6.0,
                        help="Only without app.log: seconds without new text before Stop (default: 6)")
    # Reading a big web search result can take several minutes on a MacBook Air
    # (measured: 281 s for a 16k-token prompt), with no database writes meanwhile.
    parser.add_argument("--stall", type=float, default=900.0,
                        help="Seconds without any signal before going back to idle (default: 900)")
    parser.add_argument("--heartbeat", type=float, default=HEARTBEAT,
                        help=f"Seconds between repeats of the current event during a turn (default: {HEARTBEAT})")
    parser.add_argument("--selftest", action="store_true",
                        help="Send SessionStart, UserPromptSubmit and Stop to ThatPet, then exit")
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR,
                        help="Folder for the lock file and health.json")
    parser.add_argument("--wait-for-lock", action="store_true",
                        help="If another bridge is running, wait for it instead of exiting (used by launchd)")
    args = parser.parse_args()
    if min(args.poll, args.idle, args.stall, args.heartbeat) <= 0:
        parser.error("--poll, --idle, --stall and --heartbeat must be positive")
    if not args.pet.is_file():
        sys.exit(f"ThatPet app not found: {args.pet}")
    pet = Pet(args.pet)
    if args.selftest:
        sys.exit(selftest(pet))
    if not args.db.is_file():
        sys.exit(f"Ollama database not found: {args.db}")

    # launchd stops processes with SIGTERM: turn it into a clean exit.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    trim_log()
    lock = acquire_lock(args.state_dir / "bridge.lock", args.wait_for_lock)
    if lock is None:
        sys.exit(1)

    db = OllamaDB(args.db)
    applog = LogFollower(args.log)
    try:
        last_id = db.max_id()
        last_call_id = db.max_tool_call_id()
    except sqlite3.Error as error:
        sys.exit(f"Cannot open the database: {error}")
    db.changed()  # remember the current state of the files
    health = Health(args.state_dir / "health.json")
    health.update(pid=os.getpid(), stalled_turns=0, read_problem=None)

    turn = None
    stream_error = None  # (outcome, time) of the last "chat stream error" line
    previous_problem = None
    next_trim = time.monotonic() + 600

    def set_phase(label):
        """Current phase for the menu ("Thinking", "Browsing the web", ...), with its start time."""
        if turn and turn.get("label") != label:
            turn["label"] = label
            health.update(phase=label, phase_since=time.time())

    def end_turn(outcome):
        nonlocal turn
        event, description = OUTCOMES[outcome]
        seconds = time.monotonic() - turn["started"]
        log(f"Turn ended: {description} after {seconds:.1f} s")
        pet.emit(event)
        turn = None
        # The menu shows how the reply ended and notifies when a long one is ready.
        health.update(phase=None, phase_since=None, turn_since=None,
                      last_turn={"outcome": outcome, "seconds": round(seconds), "ended": time.time()})
        if outcome == "stalled" and applog.available:
            # app.log is there but its end line never came: Ollama may have changed
            health.update(stalled_turns=health.data.get("stalled_turns", 0) + 1)
        elif outcome in ("completed", "canceled", "failed"):
            health.update(stalled_turns=0)

    def follow_tools(rows, calls, latest):
        """The pet works ("Browsing the web…" for web tools) from the tool call until the
        model starts writing again, then thinks."""
        for _, name, chat, created in calls:
            key = ("call", created, name)  # Ollama rewrites tool_calls with new ids
            if chat != turn["chat"] or not is_fresh(created, turn["since"]) or key in turn["seen"]:
                continue
            turn["seen"].add(key)
            if not turn["tool"]:
                turn["tool"] = name or "tool"
                log(f"Tool call: {turn['tool']}")
                pet.emit("PreToolUse", tool=turn["tool"])
                turn["phase"], turn["last_emit"] = ("PreToolUse", turn["tool"]), time.monotonic()
                set_phase(tool_label(turn["tool"]))
        for r in rows:
            key = ("result", r[3])
            if (r[2] == "tool" and r[1] == turn["chat"] and is_fresh(r[3], turn["since"])
                    and key not in turn["seen"]):
                turn["seen"].add(key)
                if turn["tool"]:
                    turn["tool_result_at"] = parse_time(r[3])
                    log(f"Tool finished: {turn['tool']} (the model is reading the result)")
        # A reply created after the result, with text in it: the model is writing again.
        if (turn["tool"] and turn["tool_result_at"] and latest
                and latest[0] > turn["tool_result_at"] and latest[1] > 0):
            log("Model is writing the answer")
            pet.emit("PostToolUse")
            pet.emit("UserPromptSubmit")
            turn["tool"] = turn["tool_result_at"] = None
            turn["phase"], turn["last_emit"] = ("UserPromptSubmit", None), time.monotonic()
            set_phase("Writing the answer")

    health.update(phase=None, phase_since=None, turn_since=None)
    log("Bridge v3 started. Press Ctrl+C to stop it.")
    log("Reply end detected from " + (f"{args.log}" if applog.available else
        f"a {args.idle:g} s timeout (app.log not found)"))
    log("SessionEnd is never sent.")
    log(f"ThatPet running (pid {pet.pid})" if pet.pid else
        "WARNING: ThatPet does not seem to be open. Open it before chatting.")

    try:
        while True:
            now = time.monotonic()
            pet.watch(now)
            health.update(end_detection="app.log" if applog.available else "timeout")
            if now >= next_trim:
                trim_log()
                next_trim = now + 600

            try:
                # 1) Database: a freshly created message with no active turn = turn start.
                if db.changed():
                    rows = db.rows_after(last_id)
                    if rows:
                        last_id = rows[-1][0]
                    calls = db.tool_calls_after(last_call_id) if last_call_id is not None else []
                    if calls:
                        last_call_id = calls[-1][0]
                    if turn:
                        turn["activity"] = now
                    else:
                        wall, fresh, stale = time.time(), [], 0
                        for r in rows:
                            ts = parse_time(r[3])
                            if ts is None or abs(wall - ts) >= RECENT:
                                stale += 1
                            elif r[2] in ("user", "assistant"):
                                fresh.append((r, ts))
                        if stale:
                            log(f"Ignored {stale} rows with old dates (chat rewritten by Ollama)")
                        if fresh:
                            # Prefer the user's prompt; otherwise it is a regeneration.
                            row, created = next(((r, ts) for r, ts in reversed(fresh)
                                                 if r[2] == "user"), fresh[-1])
                            turn = {"chat": row[1], "since": created, "started": now,
                                    "activity": now, "reply": 0, "reply_at": now,
                                    "tool": None, "tool_result_at": None, "seen": set(),
                                    "phase": ("UserPromptSubmit", None), "last_emit": now}
                            kind = "prompt" if row[2] == "user" else "'assistant' message (regeneration?)"
                            log(f"New {kind} in chat {row[1][:8]}")
                            pet.prompt()
                            health.update(turn_since=time.time())
                            set_phase("Thinking")
                    if turn:
                        latest = db.latest_reply(turn["chat"])
                        follow_tools(rows, calls, latest)
                        size = latest[1] if latest and latest[0] >= turn["since"] - 1 else 0
                        if size and size != turn["reply"]:
                            if not turn["reply"]:
                                log(f"Model is generating (first text after {now - turn['started']:.1f} s)")
                                if not turn["tool"]:
                                    set_phase("Writing the answer")
                            turn["reply"], turn["reply_at"] = size, now

                # 2) app.log: end of the stream (completed, stopped or failed).
                for line in applog.new_lines():
                    if STREAM_ERROR in line:
                        stream_error = ("canceled" if "context canceled" in line else "failed", now)
                        continue
                    match = STREAM_END.search(line)
                    if not match:
                        continue
                    outcome = "completed" if int(match.group(1)) < 400 else "failed"
                    if stream_error and now - stream_error[1] < 5:
                        outcome = stream_error[0]
                    stream_error = None
                    if turn:
                        end_turn(outcome)
                    else:
                        log(f"Stream ended with no active turn ({outcome}): ignored")
                previous_problem = None
                health.update(read_problem=None)
            except (sqlite3.Error, OSError) as error:
                if str(error) != previous_problem:
                    log(f"Read problem: {error}; retrying")
                    previous_problem = str(error)
                    health.update(read_problem=str(error)[:200])

            # 3) Safety nets.
            if turn:
                if not applog.available and turn["reply"] and now - turn["reply_at"] >= args.idle:
                    end_turn("presumed")
                elif now - turn["activity"] >= args.stall:
                    end_turn("stalled")

            # 4) Heartbeat: keep the pet thinking/working through long phases.
            if turn and now - turn["last_emit"] >= args.heartbeat:
                event, tool = turn["phase"]
                pet.emit(event, tool=tool, quiet=True)
                turn["last_emit"] = now

            time.sleep(args.poll)
    except KeyboardInterrupt:
        print()
    finally:
        if turn:
            end_turn("stopped")
        db.close()
        log("Bridge stopped (SessionEnd not sent)")


if __name__ == "__main__":
    main()

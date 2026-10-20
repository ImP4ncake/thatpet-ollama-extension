#!/usr/bin/env python3
"""End-to-end simulation of the bridge, without Ollama or ThatPet.

It builds a fake Ollama database and app.log, fake ThatPet/Ollama app bundles and a fake
ThatPet helper that records the events, then plays real situations (replies, stops,
errors, web searches, rewritten chats, log rotation, a second bridge, updates of ThatPet
and Ollama, ...) and checks every event the bridge sends.

    python3 tests/simulate.py "build/ThatPet Ollama Extension.app/Contents/MacOS/ThatPetOllamaExtension"

Run it after every change, before publishing a release. Expect "RESULT: ALL OK".
"""
import datetime, json, os, re, signal, sqlite3, subprocess, sys, tempfile, time
from pathlib import Path
BRIDGE = sys.argv[1]
T = Path(tempfile.mkdtemp(prefix="bridge-sim-"))
db, applog, events = T/"db.sqlite", T/"app.log", T/"events.log"
helper = T/"fake_thatpet"
LINK = T/"hermes-linked"
helper.write_text(f'''#!/bin/sh
case "$1" in
  hook) printf "%s\\n" "$(cat)" >> "{events}" ;;
  agents) if [ -f "{LINK}" ]; then echo "Hermes Agent: needsUpdate"; else echo "Hermes Agent: notInstalled"; fi ;;
  connect) touch "{LINK}" ;;
esac
''')
import plistlib
def set_version(app, version):
    (T/"apps"/f"{app}.app"/"Contents").mkdir(parents=True, exist_ok=True)
    with open(T/"apps"/f"{app}.app"/"Contents"/"Info.plist", "wb") as f:
        plistlib.dump({"CFBundleShortVersionString": version}, f)
set_version("ThatPet", "0.4.0"); set_version("Ollama", "0.40.6"); helper.chmod(0o755)
c = sqlite3.connect(db); c.execute("PRAGMA journal_mode=wal")
c.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', thinking TEXT NOT NULL DEFAULT '', created_at TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')))")
c.execute("CREATE TABLE tool_calls (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER NOT NULL, type TEXT NOT NULL, function_name TEXT NOT NULL, function_arguments TEXT NOT NULL, function_result TEXT)")
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('old','user','old'),('old','assistant','old reply')"); c.commit()
END = 'time=x level=INFO source=ui.go:246 msg=site.serveHTTP http.method=POST http.path=/api/v1/chat/{c} http.pattern="POST /api/v1/chat/{{id}}" http.status={s} http.d=3s request_id=1'
applog.write_text(END.format(c="old", s=200) + "\n")
def ev(): return [json.loads(l)["hook_event_name"] for l in events.read_text().splitlines() if l.strip()] if events.exists() else []
def log_line(s): open(applog, "a").write(s + "\n")
def turn(chat, finish, grow=3):
    c.execute("INSERT INTO messages(chat_id,role,content) VALUES (?,?,?)", (chat, "user", "hi")); c.commit(); time.sleep(0.5)
    c.execute("INSERT INTO messages(chat_id,role) VALUES (?, 'assistant')", (chat,)); c.commit()
    for _ in range(grow):
        c.execute("UPDATE messages SET content = content || 'abc' WHERE id=(SELECT max(id) FROM messages)"); c.commit(); time.sleep(0.3)
    finish(chat); time.sleep(0.6)
def start(*extra, out=subprocess.PIPE):
    base = [sys.executable, "-I", BRIDGE] if BRIDGE.endswith(".py") else [BRIDGE, "--bridge"]
    return subprocess.Popen(base + ["--db", str(db), "--log", str(applog), "--pet", str(helper), "--poll", "0.1", "--state-dir", str(T/"state"), "--thatpet-app", str(T/"apps"/"ThatPet.app"), "--ollama-app", str(T/"apps"/"Ollama.app"), "--update-check", "0.3", *extra], stdout=out, stderr=subprocess.STDOUT, text=True)
ok, ALL = True, []
def check(name, expected):
    global ok
    got = ev(); events.unlink(missing_ok=True); ALL.extend(got)
    good = got == expected; ok &= good
    print(f"{'OK ' if good else 'ERR'} {name}: {got}" + ("" if good else f"  (expected {expected})"))
cancel = 'time=x level=ERROR source=ui.go:1292 msg="chat stream error" error="context canceled"'
fail = 'time=x level=ERROR source=ui.go:1292 msg="chat stream error" error="model failed to load"'
p = start(); time.sleep(1)
check("startup: history ignored", [])
turn("chatA", lambda ch: log_line(END.format(c=ch, s=200)))
check("completed turn", ["SessionStart", "UserPromptSubmit", "Stop"])
turn("chatA", lambda ch: (log_line(cancel), log_line(END.format(c=ch, s=200))))
check("stopped turn", ["UserPromptSubmit", "SessionStart"])
turn("chatB", lambda ch: (log_line(fail), log_line(END.format(c=ch, s=200))))
check("failed turn", ["UserPromptSubmit", "StopFailure"])
os.rename(applog, T/"app-1.log"); applog.write_text("time=x level=INFO msg=start\n"); time.sleep(0.5)
turn("chatC", lambda ch: log_line(END.format(c=ch, s=200)))
check("after app.log rotation", ["UserPromptSubmit", "Stop"])
def split_write(ch):
    s = END.format(c=ch, s=200); open(applog, "a").write(s[:40]); time.sleep(0.4); open(applog, "a").write(s[40:] + "\n")
turn("chatC", split_write)
check("end line split across reads", ["UserPromptSubmit", "Stop"])
log_line(END.format(c="x", s=200)); time.sleep(0.5)
check("stream end without a turn", [])
c.execute("INSERT INTO messages(chat_id,role) VALUES ('chatC','assistant')"); c.commit(); time.sleep(0.5); log_line(END.format(c="chatC", s=200)); time.sleep(0.5)
check("regeneration", ["UserPromptSubmit", "Stop"])
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatD','user','x')"); c.commit(); time.sleep(0.5)
p.send_signal(signal.SIGTERM); first_log = p.communicate(timeout=10)[0]
check("SIGTERM with an open turn", ["UserPromptSubmit", "SessionStart"])
p = start("--stall", "1.5"); time.sleep(0.8)
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatE','user','x')"); c.commit(); time.sleep(2.5)
p.terminate(); p.communicate(timeout=10)
check("stall", ["SessionStart", "UserPromptSubmit", "SessionStart"])
p = start("--log", str(T/"missing.log"), "--idle", "1"); time.sleep(0.8)
turn("chatF", lambda ch: None); time.sleep(1.5)
p.terminate(); p.communicate(timeout=10)
check("fallback without app.log", ["SessionStart", "UserPromptSubmit", "Stop"])
p = start(); time.sleep(0.8)
c.execute("DELETE FROM messages WHERE chat_id='chatA'")
c.executemany("INSERT INTO messages(chat_id,role,content,created_at) VALUES (?,?,?,?)",
  [("chatA","user","x","2026-10-19 21:34:58.72781+02:00"), ("chatA","assistant","long old reply","2026-10-19 21:34:59.124+02:00")]); c.commit(); time.sleep(0.8)
check("chat rewritten while idle", [])
now_local = datetime.datetime.now().astimezone(); z = now_local.strftime("%z")
go = now_local.strftime("%Y-%m-%d %H:%M:%S.") + f"{now_local.microsecond:06d}"[:5] + z[:3] + ":" + z[3:]
c.execute("DELETE FROM messages WHERE chat_id='chatA'")
c.executemany("INSERT INTO messages(chat_id,role,content,created_at) VALUES (?,?,?,?)",
  [("chatA","user","x","2026-10-19 21:34:58.72781+02:00"), ("chatA","assistant","long old reply","2026-10-19 21:34:59.124+02:00"), ("chatA","user","new",go)]); c.commit(); time.sleep(1.2)
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatA','assistant','abc')"); c.commit(); time.sleep(0.5)
log_line(END.format(c="chatA", s=200)); time.sleep(0.5)
p.terminate(); out2 = p.communicate(timeout=10)[0]
check("rewrite + new prompt (Go date with offset)", ["SessionStart", "UserPromptSubmit", "Stop"])
m = re.search(r"first text after ([0-9.]+) s", out2); delay = float(m.group(1)) if m else -1
good = delay >= 1.0; ok &= good
print(f"{'OK ' if good else 'ERR'} first text measured on the new reply: {delay} s (expected >= 1.0)")

import json
def health(): return json.loads((T/"state"/"health.json").read_text())
OLD = "2026-10-19 21:00:00.123+02:00"
NOW = "strftime('%Y-%m-%d %H:%M:%f','now')"
def tool_turn(chat, rewritten=False, text_first=False, phantom=False):
    c.execute("INSERT INTO messages(chat_id,role,content) VALUES (?,?,?)", (chat, "user", "search")); c.commit(); time.sleep(0.5)
    when = f"'{OLD}'" if rewritten else NOW
    cur = c.execute(f"INSERT INTO messages(chat_id,role,content,created_at) VALUES (?,?,?,{when})", (chat, "assistant", "Let me search." if text_first else ""))
    call_msg = cur.lastrowid
    c.execute("INSERT INTO tool_calls(message_id,type,function_name,function_arguments) VALUES (?,?,?,?)", (call_msg, "function", "web_search", "{}")); c.commit(); time.sleep(0.6)
    c.execute(f"INSERT INTO messages(chat_id,role,content,created_at) VALUES (?,?,?,{when})", (chat, "tool", "results")); c.commit()
    time.sleep(1.5)  # the model reads the result: the pet must stay on the tool
    mid = ev()
    c.execute("INSERT INTO messages(chat_id,role,content) VALUES (?,?,?)", (chat, "assistant", "answer")); c.commit(); time.sleep(0.6)
    if phantom:  # Ollama rewrites tool_calls (new id, same message) and the tool row (same date) when saving
        c.execute("DELETE FROM tool_calls WHERE message_id=?", (call_msg,))
        c.execute("INSERT INTO tool_calls(message_id,type,function_name,function_arguments) VALUES (?,?,?,?)", (call_msg, "function", "web_search", "{}"))
        old_tool = c.execute("SELECT created_at FROM messages WHERE chat_id=? AND role='tool' ORDER BY id DESC LIMIT 1", (chat,)).fetchone()[0]
        c.execute("INSERT INTO messages(chat_id,role,content,created_at) VALUES (?,?,?,?)", (chat, "tool", "results", old_tool)); c.commit(); time.sleep(0.4)
    log_line(END.format(c=chat, s=200)); time.sleep(0.6)
    return mid
def check_mid(name, mid, expected):
    global ok
    good = mid == expected; ok &= good
    print(f"{'OK ' if good else 'ERR'} {name}: {mid}" + ("" if good else f"  (expected {expected})"))
TOOL_DONE = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"]
p = start(); time.sleep(0.8)
mid = tool_turn("chatT")
check_mid("while the model reads the result the pet stays on Browsing", mid, ["SessionStart", "UserPromptSubmit", "PreToolUse"])
check("tool turn: browsing until the answer starts, then thinking, then done", ["SessionStart", "UserPromptSubmit"] + TOOL_DONE)
mid = tool_turn("chatT", text_first=True)
check_mid("model wrote text before the tool call: still browsing while reading", mid, ["UserPromptSubmit", "PreToolUse"])
check("text before the tool call", ["UserPromptSubmit"] + TOOL_DONE)
tool_turn("chatT", phantom=True)
check("tool_calls rewritten by Ollama at the end: counted once", ["UserPromptSubmit"] + TOOL_DONE)
tool_turn("chatT", rewritten=True)
check("old tool rows rewritten by Ollama: ignored", ["UserPromptSubmit", "Stop"])

h = health(); good = h.get("stalled_turns") == 0 and h.get("end_detection") == "app.log" and h.get("read_problem") is None; ok &= good
print(f"{'OK ' if good else 'ERR'} health after normal turns: {h}")
# a second bridge: with --wait-for-lock it waits, without it exits at once
pB = start("--wait-for-lock"); pC = start()
outC = pC.communicate(timeout=10)[0]
good = pC.returncode == 1 and "Another bridge is already running" in outC; ok &= good
print(f"{'OK ' if good else 'ERR'} second bridge without --wait-for-lock exits (code {pC.returncode})")
turn("chatL", lambda ch: log_line(END.format(c=ch, s=200)))
check("two bridges running: events not doubled", ["UserPromptSubmit", "Stop"])
p.terminate(); p.communicate(timeout=10); time.sleep(1)
turn("chatL", lambda ch: log_line(END.format(c=ch, s=200)))
check("waiting bridge takes over when the first stops", ["SessionStart", "UserPromptSubmit", "Stop"])
pB.terminate(); outB = pB.communicate(timeout=10)[0]
good = "waiting until it stops" in outB; ok &= good
print(f"{'OK ' if good else 'ERR'} waiting bridge logged that it was waiting")
# stall with app.log present -> health warns; missing app.log -> timeout mode
p = start("--stall", "1"); time.sleep(0.8)
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatS','user','x')"); c.commit(); time.sleep(2)
h = health(); good = h.get("stalled_turns") == 1; ok &= good
print(f"{'OK ' if good else 'ERR'} health after a reply end never seen: stalled_turns={h.get('stalled_turns')}")
p.terminate(); p.communicate(timeout=10); events.unlink(missing_ok=True)
p = start("--log", str(T/"missing.log")); time.sleep(1)
h = health(); good = h.get("end_detection") == "timeout"; ok &= good
print(f"{'OK ' if good else 'ERR'} health without app.log: end_detection={h.get('end_detection')}")
p.terminate(); p.communicate(timeout=10)
# log over 1 MB, opened for appending like launchd does -> trimmed to its last part
big = T/"bridge-out.log"
with open(big, "wb") as f:
    for i in range(30000):
        f.write(f"[00:00:00] old line {i:06d} ..................................\n".encode())
before = big.stat().st_size
with open(big, "a") as out:
    p = start(out=out); time.sleep(1.5); p.terminate(); p.communicate(timeout=10)
text = big.read_text(); first = text.splitlines()[0]
good = big.stat().st_size < 300_000 and first.startswith("[00:00:00] old line") and "Log trimmed" in text and ("Bridge v3 started" in text or "Bridge started" in text); ok &= good
print(f"{'OK ' if good else 'ERR'} log trimmed: {before // 1000} KB -> {big.stat().st_size // 1000} KB, first line intact: {first[:30]}")
# heartbeat: the current event is repeated during long phases (here every 1 s instead of 20)
def payloads(): return [json.loads(l) for l in events.read_text().splitlines()] if events.exists() else []
p = start("--heartbeat", "1"); time.sleep(0.8)
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatH','user','x')"); c.commit()
time.sleep(3.6)  # long thinking phase
thinking = [e["hook_event_name"] for e in payloads()]
cur = c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatH','assistant','')")
c.execute("INSERT INTO tool_calls(message_id,type,function_name,function_arguments) VALUES (?,?,?,?)", (cur.lastrowid, "function", "web_search", "{}")); c.commit(); time.sleep(0.5)
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatH','tool','results')"); c.commit()
time.sleep(3.2)  # long reading phase
browsing = [(e["hook_event_name"], e.get("tool_name")) for e in payloads()][len(thinking):]
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatH','assistant','answer')"); c.commit(); time.sleep(0.5)
log_line(END.format(c="chatH", s=200)); time.sleep(2.5)  # after the end: no more repeats
after = [e["hook_event_name"] for e in payloads()]
p.terminate(); out = p.communicate(timeout=10)[0]; events.unlink(missing_ok=True)
good = thinking[:2] == ["SessionStart", "UserPromptSubmit"] and thinking[2:].count("UserPromptSubmit") >= 2 and set(thinking[2:]) == {"UserPromptSubmit"}; ok &= good
print(f"{'OK ' if good else 'ERR'} heartbeat while thinking: {thinking}")
good = browsing[0] == ("PreToolUse", "web_search") and len(browsing) >= 3 and all(b == ("PreToolUse", "web_search") for b in browsing); ok &= good
print(f"{'OK ' if good else 'ERR'} heartbeat while browsing keeps tool_name: {browsing}")
tail = after[len(thinking) + len(browsing):]
good = tail == ["PostToolUse", "UserPromptSubmit", "Stop"]; ok &= good
print(f"{'OK ' if good else 'ERR'} answer, done, then no more repeats: {tail}")
good = out.count("Hook sent: UserPromptSubmit") == 2 and "Hook sent: PreToolUse" in out and out.count("Hook sent: PreToolUse") == 1; ok &= good
print(f"{'OK ' if good else 'ERR'} heartbeats are not written to the log")

# phases published in health.json for the menu
p = start(); time.sleep(0.8)
def phase(): return health().get("phase")
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatP','user','x')"); c.commit(); time.sleep(0.6)
seen = [phase()]
cur = c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatP','assistant','')")
c.execute("INSERT INTO tool_calls(message_id,type,function_name,function_arguments) VALUES (?,?,?,?)", (cur.lastrowid, "function", "web_search", "{}")); c.commit(); time.sleep(0.5)
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatP','tool','results')"); c.commit(); time.sleep(0.5)
seen.append(phase())
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatP','assistant','answer')"); c.commit(); time.sleep(0.5)
seen.append(phase())
h_mid = health()
log_line(END.format(c="chatP", s=200)); time.sleep(0.6)
h_end = health()
good = seen == ["Thinking", "Browsing the web", "Writing the answer"]; ok &= good
print(f"{'OK ' if good else 'ERR'} phases shown in the menu: {seen}")
good = h_mid.get("turn_since") and h_mid.get("phase_since") and h_mid["phase_since"] >= h_mid["turn_since"]; ok &= bool(good)
print(f"{'OK ' if good else 'ERR'} phase and reply start times are published")
lt = h_end.get("last_turn") or {}
good = h_end.get("phase") is None and lt.get("outcome") == "completed" and isinstance(lt.get("seconds"), int) and lt.get("ended"); ok &= bool(good)
print(f"{'OK ' if good else 'ERR'} after the reply: phase cleared, last_turn={lt}")
c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatP','user','x')"); c.commit(); time.sleep(0.5)
cur = c.execute("INSERT INTO messages(chat_id,role,content) VALUES ('chatP','assistant','')")
c.execute("INSERT INTO tool_calls(message_id,type,function_name,function_arguments) VALUES (?,?,?,?)", (cur.lastrowid, "function", "calculator", "{}")); c.commit(); time.sleep(0.5)
other = phase()
log_line(END.format(c="chatP", s=200)); time.sleep(0.6)
good = other == "Using calculator"; ok &= good
print(f"{'OK ' if good else 'ERR'} other tools: {other}")
p.terminate(); p.communicate(timeout=10); events.unlink(missing_ok=True)

# checks after updates
p = start(); time.sleep(1)
before = health().get("update_check")
set_version("Ollama", "0.99.0"); time.sleep(1.2)
u = health().get("update_check") or {}
good = before is None and u.get("apps") == "Ollama 0.99.0" and u.get("problems") == [] and u.get("waiting_reply") is True; ok &= good
print(f"{'OK ' if good else 'ERR'} Ollama update: checks pass, waiting for a reply: {u}")
turn("chatU", lambda ch: log_line(END.format(c=ch, s=200)))
u = health().get("update_check") or {}
good = u.get("waiting_reply") is False and u.get("problems") == []; ok &= good
print(f"{'OK ' if good else 'ERR'} next reply confirms the Ollama update: waiting={u.get('waiting_reply')} problems={u.get('problems')}")
events.unlink(missing_ok=True); LINK.unlink(missing_ok=True)
set_version("ThatPet", "0.5.0"); time.sleep(1.2)
u = health().get("update_check") or {}
sent = ev(); events.unlink(missing_ok=True)
good = (u.get("apps") == "ThatPet 0.5.0" and u.get("problems") == [] and "link to ThatPet restored" in u.get("notes", [])
        and LINK.exists() and sent == ["SessionStart"]); ok &= good
print(f"{'OK ' if good else 'ERR'} ThatPet update that dropped the link: restored automatically, helper answers: {u} events={sent}")
c.execute("ALTER TABLE messages RENAME COLUMN created_at TO created"); c.commit()
set_version("Ollama", "1.0.0"); time.sleep(1.5)
u = health().get("update_check") or {}
good = "Ollama's database changed" in u.get("problems", []) and u.get("waiting_reply") is False; ok &= good
print(f"{'OK ' if good else 'ERR'} Ollama update that changed the database: reported: {u.get('problems')}")
p.terminate(); out = p.communicate(timeout=10)[0]
good = "Ollama updated: 0.40.6 -> 0.99.0" in out and "ThatPet updated: 0.4.0 -> 0.5.0" in out and "WARNING after the update" in out; ok &= good
print(f"{'OK ' if good else 'ERR'} update checks are written to the log")

print("SessionEnd never sent:", "SessionEnd" not in ALL, "- total events:", len(ALL))
print("RESULT:", "ALL OK" if ok else "ERRORS")

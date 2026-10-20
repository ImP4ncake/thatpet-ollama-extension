#!/usr/bin/env python3
"""Tests the self-update against a fake GitHub feed served locally (nothing is published).

    python3 tests/update_test.py        (after scripts/build.sh; uses your signing key)

Cases: a newer signed release installs; a bad signature, an older/same version and a signed
zip of another app are refused. Expect "RESULT: ALL OK".
"""
import functools, http.server, json, os, plistlib, shutil, subprocess, sys, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILT = ROOT / "build" / "ThatPet Ollama Extension.app"
T = Path(tempfile.mkdtemp(prefix="update-test-"))
FEED = T / "feed"; FEED.mkdir()
ok = True


def version_of(app):
    with open(app / "Contents/Info.plist", "rb") as f:
        return plistlib.load(f)["CFBundleShortVersionString"]


def variant(version, bundle_id=None):
    """A copy of the built app with another version (and maybe another bundle id), re-signed."""
    app = T / f"variant-{version}-{bundle_id or 'same'}" / BUILT.name
    shutil.rmtree(app, ignore_errors=True)
    shutil.copytree(BUILT, app, symlinks=True)
    plist = app / "Contents/Info.plist"
    with open(plist, "rb") as f:
        info = plistlib.load(f)
    info["CFBundleShortVersionString"] = version
    if bundle_id:
        info["CFBundleIdentifier"] = bundle_id
    with open(plist, "wb") as f:
        plistlib.dump(info, f)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def publish(app, version, good_signature=True):
    """Zips and signs `app` into the feed and writes latest.json for tag v<version>."""
    zip_path = FEED / f"ThatPet-Ollama-Extension-{version}.zip"
    zip_path.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(zip_path)], check=True)
    signed = zip_path
    if not good_signature:  # sign something else and put that signature next to the zip
        signed = FEED / "other.bin"
        signed.write_bytes(b"not the zip")
    subprocess.run(["swift", str(ROOT / "scripts/signing.swift"), "sign", str(signed)], check=True,
                   capture_output=True, cwd=ROOT)
    if not good_signature:
        os.replace(str(signed) + ".sig", str(zip_path) + ".sig")
    base = f"http://127.0.0.1:{PORT}/"
    (FEED / "latest.json").write_text(json.dumps({
        "tag_name": f"v{version}", "html_url": base,
        "assets": [{"name": zip_path.name, "browser_download_url": base + zip_path.name},
                   {"name": zip_path.name + ".sig", "browser_download_url": base + zip_path.name + ".sig"}]}))


def installed():
    """A fresh 'installed' copy of the built app."""
    target = T / "Applications" / BUILT.name
    shutil.rmtree(target, ignore_errors=True)
    target.parent.mkdir(exist_ok=True)
    shutil.copytree(BUILT, target, symlinks=True)
    return target


def update(app):
    env = dict(os.environ, TPOE_UPDATE_FEED=f"http://127.0.0.1:{PORT}/latest.json")
    result = subprocess.run([str(app / "Contents/MacOS/ThatPetOllamaExtension"), "--update-now"],
                            env=env, capture_output=True, text=True, timeout=120)
    return (result.stdout + result.stderr).strip()


def check(name, good, detail):
    global ok
    ok &= good
    print(f"{'OK ' if good else 'ERR'} {name}: {detail}")


handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(FEED))
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

current = version_of(BUILT)
newer = ".".join(current.split(".")[:2] + [str(int(current.split(".")[2]) + 1)])

app = installed()
publish(variant(newer), newer)
out = update(app)
check("newer signed release installs", version_of(app) == newer and "Installed" in out, f"{out} -> {version_of(app)}")
verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
check("installed app keeps a valid code signature", verify.returncode == 0, f"codesign exit {verify.returncode}")

app = installed()
publish(variant(newer), newer, good_signature=False)
out = update(app)
check("bad signature refused", version_of(app) == current and "signature does not match" in out, out)

app = installed()
publish(variant(current), current)
out = update(app)
check("same version: nothing to do", version_of(app) == current and "upToDate" in out, out)

app = installed()
publish(variant(newer, bundle_id="com.example.other"), newer)
out = update(app)
check("signed zip of another app refused", version_of(app) == current and "not this app" in out, out)

server.shutdown()
shutil.rmtree(T, ignore_errors=True)
print("RESULT:", "ALL OK" if ok else "ERRORS")
sys.exit(0 if ok else 1)

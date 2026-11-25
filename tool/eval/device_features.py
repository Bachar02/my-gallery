"""Extracts real ML Kit features (OCR lines with positions, face counts) for
the evaluation corpus on a connected Android device or emulator.

Runs integration_test/eval/ocr_dump_test.dart, pushes every corpus image into
the app's external files directory once the app is installed, and pulls the
result to tool/eval/features/device_features.json (committed: the Dart
evaluation reads it, so `flutter test` needs neither the images nor a device).

Usage: tool/.venv/Scripts/python -I tool/eval/device_features.py [-d emulator-5554]
Run no other flutter/gradle command at the same time.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "tool" / "eval" / ".data"
OUT = ROOT / "tool" / "eval" / "features" / "device_features.json"
PKG = "com.bachar02.ai_gallery"
REMOTE = f"/sdcard/Android/data/{PKG}/files/eval"


def adb_path() -> str:
    found = shutil.which("adb")
    if found:
        return found
    sdk = os.environ.get("ANDROID_HOME") or os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk")
    return os.path.join(sdk, "platform-tools", "adb.exe" if os.name == "nt" else "adb")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-d", "--device", default="emulator-5554")
    args = ap.parse_args()
    adb = [adb_path(), "-s", args.device]
    files = sorted(list((DATA / "photos").glob("*.jpg")) + list((DATA / "screens").glob("*.png")))
    if not files:
        raise SystemExit("no corpus images; run make_screens.py and fetch_photos.py first")

    flutter = shutil.which("flutter") or shutil.which("flutter.bat")
    test = subprocess.Popen([flutter, "test", "integration_test/eval/ocr_dump_test.dart", "-d", args.device],
                            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")
    pushed = False
    tmp = DATA / "device_features.json"
    staging = DATA / "device_in"
    for line in test.stdout:
        sys.stdout.write(line)
        if not pushed and "[eval] waiting for" in line:
            # The app created its external files dir; push the corpus.
            if staging.exists():
                shutil.rmtree(staging)
            staging.mkdir(parents=True)
            for f in files:
                shutil.copyfile(f, staging / f.name)
            subprocess.run(adb + ["shell", "rm", "-rf", f"{REMOTE}/in", f"{REMOTE}/out"], check=False)
            subprocess.run(adb + ["shell", "mkdir", "-p", f"{REMOTE}/in"], check=True)
            subprocess.run(adb + ["push", "--sync", str(staging) + "/.", f"{REMOTE}/in/"], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(adb + ["shell", "touch", f"{REMOTE}/in/READY"], check=True)
            pushed = True
            print(f"[driver] pushed {len(files)} images", flush=True)
        if "[eval] done" in line:
            # Pull now: flutter test uninstalls the app (and its files) at the end.
            subprocess.run(adb + ["pull", f"{REMOTE}/out/features.json", str(tmp)], check=True)
            subprocess.run(adb + ["shell", "touch", f"{REMOTE}/out/PULLED"], check=False)
            print("[driver] pulled features", flush=True)
    code = test.wait()
    if code != 0:
        raise SystemExit(f"device test failed ({code})")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    data = json.loads(tmp.read_text(encoding="utf-8"))
    OUT.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
                   encoding="utf-8")
    subprocess.run(adb + ["shell", "rm", "-rf", REMOTE], check=False)
    shutil.rmtree(staging, ignore_errors=True)
    print(f"[driver] wrote {OUT} ({len(data)} images)")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    t = time.time()
    main()
    print(f"[driver] {time.time() - t:.0f} s")

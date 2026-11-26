"""Puts the evaluation corpus into a device's gallery and runs the on-device
search verification (integration_test/eval/device_search_test.dart).

Photos go to Pictures/EvalCorpus/, screenshots to Pictures/Screenshots/ (so
MediaStore classifies them as screenshots), named <corpus id>.<ext>; then a
media scan. The test is started with flutter, and READ_MEDIA_IMAGES is granted
as soon as the app is installed. --remove deletes the pushed files.

Usage: tool/.venv/Scripts/python -I tool/eval/push_gallery.py [-d emulator-5554] [--remove]
Run no other flutter/gradle command at the same time.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from device_features import PKG, adb_path  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "tool" / "eval" / ".data"
PHOTO_DIR = "/sdcard/Pictures/EvalCorpus"
SCREEN_DIR = "/sdcard/Pictures/Screenshots"


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("-d", "--device", default="emulator-5554")
    ap.add_argument("--remove", action="store_true")
    args = ap.parse_args()
    adb = [adb_path(), "-s", args.device]
    if args.remove:
        subprocess.run(adb + ["shell", "rm", "-rf", PHOTO_DIR, SCREEN_DIR], check=False)
        subprocess.run(adb + ["shell", "content", "call", "--method", "scan_volume", "--uri", "content://media",
                              "--arg", "external_primary"], check=False)
        return
    subprocess.run(adb + ["shell", "mkdir", "-p", PHOTO_DIR, SCREEN_DIR], check=True)
    subprocess.run(adb + ["push", "--sync", str(DATA / "photos") + "/.", PHOTO_DIR + "/"], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(adb + ["push", "--sync", str(DATA / "screens") + "/.", SCREEN_DIR + "/"], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(adb + ["shell", "content", "call", "--method", "scan_volume", "--uri", "content://media",
                          "--arg", "external_primary"], check=False, stdout=subprocess.DEVNULL)
    print("[push] corpus pushed and scanned", flush=True)

    def grant_when_installed() -> None:
        for _ in range(900):
            out = subprocess.run(adb + ["shell", "pm", "path", PKG], capture_output=True, text=True).stdout
            if "package:" in out:
                time.sleep(2)
                subprocess.run(adb + ["shell", "pm", "grant", PKG, "android.permission.READ_MEDIA_IMAGES"], check=False)
                print("[push] permission granted", flush=True)
                return
            time.sleep(1)

    threading.Thread(target=grant_when_installed, daemon=True).start()
    flutter = shutil.which("flutter") or shutil.which("flutter.bat")
    code = subprocess.call([flutter, "test", "integration_test/eval/device_search_test.dart", "-d", args.device],
                           cwd=ROOT)
    raise SystemExit(code)


if __name__ == "__main__":
    main()

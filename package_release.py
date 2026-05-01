#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from build_launcher import APP_BUILD, APP_NAME, APP_VERSION, build_app

ROOT = Path(__file__).resolve().parent
RELEASE_DIR = ROOT / "release"
PACKAGE_NAME = f"{APP_NAME}-{APP_VERSION}-{APP_BUILD}-macOS-universal"
PACKAGE_DIR = RELEASE_DIR / PACKAGE_NAME
ZIP_PATH = RELEASE_DIR / f"{PACKAGE_NAME}.zip"
DMG_PATH = RELEASE_DIR / f"{PACKAGE_NAME}.dmg"


def run(command: list[str]) -> None:
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Command failed")


def write_quick_start() -> None:
    text = f"""Zalo Scheduler {APP_VERSION} ({APP_BUILD})

Cach chuyen sang may moi:
1. Mo file DMG hoac ZIP nay.
2. Keo {APP_NAME}.app vao Applications.
3. Mo Zalo tren may moi va dang nhap tai khoan can gui.
4. Mo {APP_NAME}.app.
5. Trong app, bam "Yeu cau quyen" va bat Accessibility cho {APP_NAME}.
6. Bam "Lam moi" o muc Zalo gui tin, chon dung ban Zalo dang mo.
7. Kiem tra lai lich gui, anh/video dinh kem, roi bam "Bat dau chay lich".

May moi khong can cai Python, Swift hay Xcode de su dung app da dong goi.

Luu y:
- Can macOS 13 tro len.
- Neu macOS chan app lan dau, chuot phai vao app va chon Open.
- Zalo phai dang mo va da dang nhap.
- Neu lich co anh/video/file, cac tep do phai ton tai tren may moi.
- Neu copy cau hinh tu may cu, kiem tra lai duong dan file dinh kem vi ten user/thu muc co the khac.
"""
    (PACKAGE_DIR / "HUONG_DAN_CAI_DAT.txt").write_text(text, encoding="utf-8")


def prepare_package_dir(app_path: Path) -> None:
    if PACKAGE_DIR.exists():
        shutil.rmtree(PACKAGE_DIR)
    PACKAGE_DIR.mkdir(parents=True, exist_ok=True)

    shutil.copytree(app_path, PACKAGE_DIR / app_path.name, symlinks=True)
    applications_link = PACKAGE_DIR / "Applications"
    if not applications_link.exists():
        os.symlink("/Applications", applications_link)
    write_quick_start()


def create_zip() -> None:
    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(PACKAGE_DIR), str(ZIP_PATH)])


def create_dmg() -> None:
    if DMG_PATH.exists():
        DMG_PATH.unlink()
    run([
        "hdiutil",
        "create",
        "-volname",
        APP_NAME,
        "-srcfolder",
        str(PACKAGE_DIR),
        "-ov",
        "-format",
        "UDZO",
        str(DMG_PATH),
    ])


def main() -> int:
    RELEASE_DIR.mkdir(parents=True, exist_ok=True)
    app_path = build_app()
    prepare_package_dir(app_path)
    create_zip()
    create_dmg()
    print(ZIP_PATH)
    print(DMG_PATH)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

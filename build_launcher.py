#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DIST_DIR = ROOT / "dist"
APP_NAME = "ZaloSchedulerLauncher"
APP_VERSION = "1.5.0"
APP_BUILD = "8"
APP_DIR = DIST_DIR / f"{APP_NAME}.app"
CONTENTS_DIR = APP_DIR / "Contents"
MACOS_DIR = CONTENTS_DIR / "MacOS"
RESOURCES_DIR = CONTENTS_DIR / "Resources"
TEMP_BUILD_DIR = DIST_DIR / "build"
LAUNCHER_SRC = ROOT / "launcher" / "ZaloSchedulerLauncher.swift"
HELPER_SRC = ROOT / "zalo_helper.swift"
HELPER_MAIN_SRC = ROOT / "helper_main.swift"
EXECUTABLE_PATH = MACOS_DIR / APP_NAME
ARCH_TARGETS = [
    ("arm64", "arm64-apple-macos13.0"),
    ("x86_64", "x86_64-apple-macos13.0"),
]


def run(command: list[str]) -> None:
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Command failed")


def sign_app() -> None:
    run(["codesign", "--force", "--deep", "--sign", "-", str(APP_DIR)])


def write_info_plist() -> None:
    plist_text = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>{APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>{APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.ZaloSchedulerLauncher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>{APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>{APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>{APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
"""
    (CONTENTS_DIR / "Info.plist").write_text(plist_text, encoding="utf-8")


def copy_resources() -> None:
    shutil.copy2(ROOT / "main.py", RESOURCES_DIR / "main.py")
    shutil.copy2(ROOT / "zalo_helper.swift", RESOURCES_DIR / "zalo_helper.swift")
    shutil.copy2(ROOT / "helper_main.swift", RESOURCES_DIR / "helper_main.swift")
    shutil.copy2(ROOT / "README.md", RESOURCES_DIR / "README.md")

    resource_config_dir = RESOURCES_DIR / "config"
    resource_config_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "config" / "jobs.example.json", resource_config_dir / "jobs.example.json")


def build_universal_executable() -> None:
    if TEMP_BUILD_DIR.exists():
        shutil.rmtree(TEMP_BUILD_DIR)
    TEMP_BUILD_DIR.mkdir(parents=True, exist_ok=True)

    binaries: list[Path] = []
    for arch, target in ARCH_TARGETS:
        output = TEMP_BUILD_DIR / f"{APP_NAME}-{arch}"
        run(
            [
                "swiftc",
                "-O",
                "-parse-as-library",
                "-target",
                target,
                "-o",
                str(output),
                str(LAUNCHER_SRC),
                str(HELPER_SRC),
            ]
        )
        binaries.append(output)

    run(["lipo", "-create", "-output", str(EXECUTABLE_PATH), *map(str, binaries)])


def build_app() -> Path:
    if APP_DIR.exists():
        shutil.rmtree(APP_DIR)

    MACOS_DIR.mkdir(parents=True, exist_ok=True)
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)

    build_universal_executable()
    write_info_plist()
    copy_resources()
    EXECUTABLE_PATH.chmod(0o755)
    sign_app()
    return APP_DIR


if __name__ == "__main__":
    app_path = build_app()
    print(app_path)

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import json
import logging
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, time as dtime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


RESOURCE_ROOT = Path(os.environ.get("ZALO_SCHEDULER_RESOURCE_ROOT", Path(__file__).resolve().parent)).resolve()
DATA_ROOT = Path(os.environ.get("ZALO_SCHEDULER_DATA_ROOT", RESOURCE_ROOT)).resolve()
ROOT = RESOURCE_ROOT
BUILD_DIR = DATA_ROOT / "build"
CONFIG_DIR = DATA_ROOT / "config"
LOG_DIR = DATA_ROOT / "logs"
SWIFT_HELPER = RESOURCE_ROOT / "zalo_helper.swift"
SWIFT_HELPER_MAIN = RESOURCE_ROOT / "helper_main.swift"
HELPER_BIN = BUILD_DIR / "zalo_helper"
BUNDLED_APP_BIN = RESOURCE_ROOT.parent / "MacOS" / "ZaloSchedulerLauncher"
DIST_APP_BIN = RESOURCE_ROOT / "dist" / "ZaloSchedulerLauncher.app" / "Contents" / "MacOS" / "ZaloSchedulerLauncher"
DEFAULT_CONFIG = CONFIG_DIR / "jobs.example.json"
DEFAULT_STATE = CONFIG_DIR / "state.json"
RESOURCE_CONFIG_DIR = RESOURCE_ROOT / "config"
DEFAULT_TZ = ZoneInfo("Asia/Ho_Chi_Minh")


@dataclass
class DueRun:
    job_id: str
    occurrence_key: str


def setup_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(LOG_DIR / "scheduler.log", encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.setdefault("CLANG_MODULE_CACHE_PATH", str(BUILD_DIR / "module-cache"))
    return subprocess.run(
        command,
        cwd=str(DATA_ROOT),
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def active_helper_bin() -> Path:
    if BUNDLED_APP_BIN.is_file() and os.access(BUNDLED_APP_BIN, os.X_OK):
        return BUNDLED_APP_BIN
    if (
        DIST_APP_BIN.is_file()
        and os.access(DIST_APP_BIN, os.X_OK)
        and DIST_APP_BIN.stat().st_mtime >= SWIFT_HELPER.stat().st_mtime
    ):
        return DIST_APP_BIN
    return HELPER_BIN


def ensure_default_files() -> None:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    sample_config = RESOURCE_CONFIG_DIR / "jobs.example.json"
    if sample_config.exists() and not DEFAULT_CONFIG.exists():
        shutil.copy2(sample_config, DEFAULT_CONFIG)

    if not DEFAULT_STATE.exists():
        save_json(DEFAULT_STATE, {"jobs": {}})


def build_helper(force: bool = False) -> Path:
    ensure_default_files()
    active_helper = active_helper_bin()
    if active_helper != HELPER_BIN and not force:
        return active_helper
    if active_helper == BUNDLED_APP_BIN:
        return active_helper

    should_build = force or not HELPER_BIN.exists() or HELPER_BIN.stat().st_mtime < SWIFT_HELPER.stat().st_mtime
    if not should_build:
        return HELPER_BIN

    result = run_command(
        [
            "swiftc",
            "-O",
            "-o",
            str(HELPER_BIN),
            str(SWIFT_HELPER),
            str(SWIFT_HELPER_MAIN),
        ]
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Build helper thất bại.")
    return HELPER_BIN


def helper_command(*args: str) -> list[str]:
    helper_bin = build_helper()
    return [str(helper_bin), *args]


def probe() -> int:
    ensure_default_files()
    result = run_command(helper_command("probe"))
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
    return result.returncode


def accessibility_status(prompt: bool) -> int:
    ensure_default_files()
    command = "request-accessibility" if prompt else "accessibility-status"
    result = run_command(helper_command(command))
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    return result.returncode


def open_chat(recipient: str) -> int:
    ensure_default_files()
    result = run_command(helper_command("open-chat", "--recipient", recipient))
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    return result.returncode


def send_now(recipient: str, message: str | None, images: list[str]) -> int:
    ensure_default_files()
    command = ["send", "--recipient", recipient]
    if message is not None:
        command.extend(["--message", message])
    for image in images:
        command.extend(["--image", str(Path(image).expanduser().resolve())])

    result = run_command(helper_command(*command))
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    return result.returncode


def validate_config(config: dict[str, Any]) -> None:
    jobs = config.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise ValueError("Config phải có mảng 'jobs' và không được rỗng.")

    for job in jobs:
        if not isinstance(job, dict):
            raise ValueError("Mỗi job phải là object JSON.")

        required_keys = ["id", "recipient", "schedule"]
        for key in required_keys:
            if key not in job:
                raise ValueError(f"Job thiếu trường bắt buộc: {key}")

        if not isinstance(job["id"], str) or not job["id"].strip():
            raise ValueError("Job.id phải là chuỗi không rỗng.")
        if not isinstance(job["recipient"], str) or not job["recipient"].strip():
            raise ValueError(f"Job {job['id']} có recipient không hợp lệ.")

        images = job.get("images", [])
        if images is None:
            images = []
        if not isinstance(images, list):
            raise ValueError(f"Job {job['id']} có images phải là mảng đường dẫn ảnh/video.")
        for image in images:
            if not isinstance(image, str) or not image.strip():
                raise ValueError(f"Job {job['id']} có đường dẫn ảnh/video không hợp lệ.")

        message = job.get("message")
        if message is not None and not isinstance(message, str):
            raise ValueError(f"Job {job['id']} có message phải là chuỗi.")
        if not message and not images:
            raise ValueError(f"Job {job['id']} cần ít nhất tin nhắn hoặc ảnh/video.")

        schedule = job["schedule"]
        if not isinstance(schedule, dict):
            raise ValueError(f"Job {job['id']} có schedule không hợp lệ.")

        schedule_type = schedule.get("type")
        if schedule_type == "once":
            if not isinstance(schedule.get("at"), str):
                raise ValueError(f"Job {job['id']} loại once cần schedule.at dạng ISO datetime.")
            parse_once_datetime(schedule["at"])
        elif schedule_type == "daily":
            at_value = schedule.get("at")
            if not isinstance(at_value, str):
                raise ValueError(f"Job {job['id']} loại daily cần schedule.at dạng HH:MM.")
            parse_daily_time(at_value)
            days = schedule.get("days", [0, 1, 2, 3, 4, 5, 6])
            if not isinstance(days, list) or not all(isinstance(day, int) and 0 <= day <= 6 for day in days):
                raise ValueError(f"Job {job['id']} có schedule.days phải là mảng số 0-6.")
        else:
            raise ValueError(f"Job {job['id']} có schedule.type không hỗ trợ: {schedule_type}")


def parse_once_datetime(value: str) -> datetime:
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=DEFAULT_TZ)
    return dt


def parse_daily_time(value: str) -> dtime:
    return datetime.strptime(value, "%H:%M").time()


def current_due_run(job: dict[str, Any], now: datetime, job_state: dict[str, Any]) -> DueRun | None:
    schedule = job["schedule"]
    schedule_type = schedule["type"]

    if schedule_type == "once":
        due_at = parse_once_datetime(schedule["at"]).astimezone(DEFAULT_TZ)
        occurrence_key = due_at.isoformat()
        if now >= due_at and job_state.get("last_occurrence_key") != occurrence_key:
            return DueRun(job_id=job["id"], occurrence_key=occurrence_key)
        return None

    if schedule_type == "daily":
        send_time = parse_daily_time(schedule["at"])
        allowed_days = schedule.get("days", [0, 1, 2, 3, 4, 5, 6])
        if now.weekday() not in allowed_days:
            return None

        due_at = now.replace(hour=send_time.hour, minute=send_time.minute, second=0, microsecond=0)
        occurrence_key = due_at.date().isoformat()
        if now >= due_at and job_state.get("last_occurrence_key") != occurrence_key:
            return DueRun(job_id=job["id"], occurrence_key=occurrence_key)
        return None

    raise ValueError(f"Schedule type không hỗ trợ: {schedule_type}")


def run_scheduler(config_path: Path, state_path: Path, poll_seconds: int) -> int:
    ensure_default_files()
    setup_logging()
    build_helper()

    config = load_json(config_path)
    validate_config(config)
    state = load_json(state_path) if state_path.exists() else {"jobs": {}}
    state.setdefault("jobs", {})

    logging.info("Bắt đầu scheduler với config=%s", config_path)
    while True:
        now = datetime.now(DEFAULT_TZ)
        for job in config["jobs"]:
            job_id = job["id"]
            job_state = state["jobs"].setdefault(job_id, {})
            due_run = current_due_run(job, now, job_state)
            if due_run is None:
                continue

            logging.info("Đến lịch gửi job=%s recipient=%s", job_id, job["recipient"])
            exit_code = send_now(
                recipient=job["recipient"],
                message=job.get("message"),
                images=job.get("images", []) or [],
            )

            if exit_code == 0:
                job_state["last_occurrence_key"] = due_run.occurrence_key
                job_state["last_success_at"] = now.isoformat()
                save_json(state_path, state)
                logging.info("Gửi thành công job=%s", job_id)
            else:
                job_state["last_error_at"] = now.isoformat()
                save_json(state_path, state)
                logging.error("Gửi thất bại job=%s", job_id)

        time.sleep(max(poll_seconds, 5))


def main() -> int:
    ensure_default_files()
    parser = argparse.ArgumentParser(description="Zalo PC scheduler cho macOS")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("build-helper")
    subparsers.add_parser("accessibility-status")
    subparsers.add_parser("request-accessibility")
    subparsers.add_parser("probe")

    open_chat_parser = subparsers.add_parser("open-chat")
    open_chat_parser.add_argument("--recipient", required=True)

    validate_parser = subparsers.add_parser("validate-config")
    validate_parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)

    send_parser = subparsers.add_parser("send-now")
    send_parser.add_argument("--recipient", required=True)
    send_parser.add_argument("--message")
    send_parser.add_argument("--image", action="append", default=[])

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    run_parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    run_parser.add_argument("--poll-seconds", type=int, default=15)

    args = parser.parse_args()

    if args.command == "build-helper":
        print(build_helper(force=True))
        return 0

    if args.command == "accessibility-status":
        return accessibility_status(prompt=False)

    if args.command == "request-accessibility":
        return accessibility_status(prompt=True)

    if args.command == "probe":
        return probe()

    if args.command == "open-chat":
        return open_chat(args.recipient)

    if args.command == "validate-config":
        config = load_json(args.config)
        validate_config(config)
        print("Config hợp lệ.")
        return 0

    if args.command == "send-now":
        return send_now(args.recipient, args.message, args.image)

    if args.command == "run":
        return run_scheduler(args.config, args.state, args.poll_seconds)

    parser.error("Lệnh không hợp lệ.")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

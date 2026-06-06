#!/usr/bin/env python3
"""
OpenClaw backup/restore helper
- Prefer S3/R2 when S3_BUCKET is configured
- Fall back to Hugging Face Dataset when S3 is not configured or fails
- Backup full /home/node/.openclaw but exclude logs/cache/tmp/node_modules and WeChat login state

Required HF envs for HF fallback:
  HF_TOKEN, HF_DATASET

Optional S3/R2 envs:
  S3_BUCKET        e.g. openclaw-backup
  S3_KEY_ID        Access Key ID
  S3_ACCESS_KEY    Secret Access Key
  S3_ENDPOINT      e.g. https://<account_id>.r2.cloudflarestorage.com
  S3_REGION        default: auto
  S3_BACKUP_PATH   default: backups/openclaw-latest.tar.gz
  S3_SNAPSHOT_PREFIX default: snapshots
"""

import os
import sys
import tarfile
import shutil
import tempfile
from pathlib import Path
from datetime import datetime, timedelta

from huggingface_hub import HfApi, hf_hub_download

BASE = Path(os.getenv("OPENCLAW_STATE_DIR", "/home/node/.openclaw"))
MANIFEST_DAYS = int(os.getenv("BACKUP_RETENTION_DAYS", "180"))

HF_REPO_ID = os.getenv("HF_DATASET")
HF_TOKEN = os.getenv("HF_TOKEN")
HF_API = HfApi()

S3_BUCKET = os.getenv("S3_BUCKET", "").strip()
S3_KEY_ID = os.getenv("S3_KEY_ID", "").strip()
S3_ACCESS_KEY = os.getenv("S3_ACCESS_KEY", "").strip()
S3_ENDPOINT = os.getenv("S3_ENDPOINT", "").strip()
S3_REGION = os.getenv("S3_REGION", "auto").strip() or "auto"
S3_BACKUP_PATH = os.getenv("S3_BACKUP_PATH", "backups/openclaw-latest.tar.gz").strip()
S3_SNAPSHOT_PREFIX = os.getenv("S3_SNAPSHOT_PREFIX", "snapshots").strip().strip("/")

# Do not backup volatile/heavy/runtime-specific directories.
EXCLUDE_PARTS = {
    "logs",
    "log",
    "cache",
    ".cache",
    "tmp",
    "temp",
    "node_modules",
    "__pycache__",
}

# Do not backup WeChat login/channel state. You said WeChat should reconnect by QR.
EXCLUDE_KEYWORDS = (
    "weixin",
    "wechat",
    "openclaw-weixin",
    "tencent-weixin",
)

EXCLUDE_SUFFIXES = (
    ".log",
    ".tmp",
    ".lock",
    ".sock",
)


def is_s3_enabled() -> bool:
    return bool(S3_BUCKET and S3_KEY_ID and S3_ACCESS_KEY and S3_ENDPOINT)


def get_s3_client():
    try:
        import boto3
        from botocore.config import Config
    except Exception as e:
        raise RuntimeError(
            "boto3 is not installed. Add `pip install boto3` to Dockerfile."
        ) from e

    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=S3_KEY_ID,
        aws_secret_access_key=S3_ACCESS_KEY,
        region_name=S3_REGION,
        config=Config(signature_version="s3v4"),
    )


def should_exclude(path: Path) -> bool:
    """Return True if this file/dir should be skipped from backup."""
    try:
        rel = path.relative_to(BASE)
    except ValueError:
        rel = path

    parts_lower = [p.lower() for p in rel.parts]
    rel_lower = str(rel).replace("\\", "/").lower()

    if any(part in EXCLUDE_PARTS for part in parts_lower):
        return True
    if any(keyword in rel_lower for keyword in EXCLUDE_KEYWORDS):
        return True
    if rel_lower.endswith(EXCLUDE_SUFFIXES):
        return True
    return False


def safe_clear_base():
    """Clear BASE before restore, but recreate it safely."""
    if BASE.exists():
        print(f"[RESTORE] Clearing existing data: {BASE}")
        shutil.rmtree(BASE)
    BASE.mkdir(parents=True, exist_ok=True)


def safe_extract_tar(tar_path: Path):
    """Safely extract a tar.gz into BASE, preventing path traversal."""
    base_resolved = BASE.resolve()
    with tarfile.open(tar_path, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            target = (BASE / member.name).resolve()
            if not str(target).startswith(str(base_resolved)):
                print(f"[RESTORE] Skipped unsafe path: {member.name}")
                continue

            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                extracted = tar.extractfile(member)
                if extracted is None:
                    continue
                with extracted as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)


def create_archive() -> Path:
    """Create backup archive and return local path."""
    BASE.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    archive_path = Path(tempfile.gettempdir()) / f"openclaw_backup_{timestamp}.tar.gz"

    added = 0
    skipped = 0

    print(f"[BACKUP] Creating OpenClaw backup: {archive_path.name}")
    print(f"[BACKUP] Base: {BASE}")
    print("[BACKUP] Excluding: logs/cache/tmp/node_modules + weixin/wechat/openclaw-weixin/tencent-weixin")

    with tarfile.open(archive_path, "w:gz") as tar:
        if not BASE.exists():
            print(f"[BACKUP] Base does not exist: {BASE}")
            return archive_path

        for path in BASE.rglob("*"):
            if should_exclude(path):
                skipped += 1
                continue
            if path.is_file():
                arcname = path.relative_to(BASE)
                tar.add(path, arcname=str(arcname), recursive=False)
                added += 1
            elif path.is_dir():
                # Directories are created implicitly by files; skip empty excluded dirs.
                pass

    print(f"[BACKUP] Files added: {added}, skipped: {skipped}")
    print(f"[BACKUP] Archive size: {archive_path.stat().st_size} bytes")
    return archive_path


def backup_to_s3(archive_path: Path):
    client = get_s3_client()
    latest_key = S3_BACKUP_PATH.lstrip("/")
    snapshot_key = f"{S3_SNAPSHOT_PREFIX}/openclaw_{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.tar.gz"

    print(f"[S3] Uploading latest: s3://{S3_BUCKET}/{latest_key}")
    client.upload_file(str(archive_path), S3_BUCKET, latest_key)

    print(f"[S3] Uploading snapshot: s3://{S3_BUCKET}/{snapshot_key}")
    client.upload_file(str(archive_path), S3_BUCKET, snapshot_key)

    print("[S3] Backup success")


def restore_from_s3(target_key: str | None = None) -> bool:
    if not is_s3_enabled():
        print("[S3] Not configured; skipping S3 restore")
        return False

    client = get_s3_client()
    key = (target_key or S3_BACKUP_PATH).lstrip("/")
    local_path = Path(tempfile.gettempdir()) / "openclaw_s3_restore.tar.gz"

    try:
        print(f"[S3] Restoring from s3://{S3_BUCKET}/{key}")
        client.download_file(S3_BUCKET, key, str(local_path))
    except Exception as e:
        print(f"[S3] Restore failed: {e}")
        return False

    # Preserve current start.sh-generated config to avoid restoring stale token/model/port.
    config_path = BASE / "openclaw.json"
    config_backup = None
    if config_path.exists():
        config_backup = config_path.read_text(errors="ignore")
        print("[RESTORE] Backed up current openclaw.json")

    safe_clear_base()
    safe_extract_tar(local_path)

    if config_backup is not None:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(config_backup)
        print("[RESTORE] Restored current openclaw.json")

    print("[S3] Restore success")
    return True


def cleanup_old_hf_backups(days: int = MANIFEST_DAYS):
    if not HF_REPO_ID:
        return
    try:
        cutoff = datetime.now() - timedelta(days=days)
        files = HF_API.list_repo_files(repo_id=HF_REPO_ID, repo_type="dataset", token=HF_TOKEN)
        for f in files:
            if f.startswith("backup_") and f.endswith(".tar.gz"):
                date_str = f[7:17]
                try:
                    backup_date = datetime.strptime(date_str, "%Y-%m-%d")
                    if backup_date < cutoff:
                        HF_API.delete_file(
                            path_in_repo=f,
                            repo_id=HF_REPO_ID,
                            repo_type="dataset",
                            token=HF_TOKEN,
                        )
                        print(f"[HF] Deleted old backup: {f}")
                except Exception:
                    pass
    except Exception as e:
        print(f"[HF] Cleanup error: {e}")


def backup_to_hf(archive_path: Path):
    if not HF_REPO_ID:
        print("[HF] HF_DATASET not set; skipping HF backup")
        return

    cleanup_old_hf_backups()
    name = f"backup_{datetime.now().strftime('%Y-%m-%d')}.tar.gz"
    print(f"[HF] Uploading backup: {name}")
    HF_API.upload_file(
        path_or_fileobj=str(archive_path),
        path_in_repo=name,
        repo_id=HF_REPO_ID,
        repo_type="dataset",
        token=HF_TOKEN,
    )
    print(f"[HF] Backup success: {name}")


def get_hf_backup_files(days: int = MANIFEST_DAYS):
    if not HF_REPO_ID:
        return []
    try:
        files = HF_API.list_repo_files(repo_id=HF_REPO_ID, repo_type="dataset", token=HF_TOKEN)
        backups = []
        cutoff = datetime.now() - timedelta(days=days)
        for f in files:
            if f.startswith("backup_") and f.endswith(".tar.gz"):
                date_str = f[7:17]
                try:
                    backup_date = datetime.strptime(date_str, "%Y-%m-%d")
                    if backup_date >= cutoff:
                        backups.append({"filename": f, "date": date_str, "date_obj": backup_date})
                except Exception:
                    pass
        return sorted(backups, key=lambda x: x["date_obj"], reverse=True)
    except Exception as e:
        print(f"[HF] List backup error: {e}")
        return []


def restore_from_hf(target_date: str | None = None, merge_days: int = 7) -> bool:
    if not HF_REPO_ID:
        print("[HF] HF_DATASET not set; skipping HF restore")
        return False

    backups = get_hf_backup_files()
    if not backups:
        print("[HF] No backups found")
        return False

    if target_date:
        target = next((b for b in backups if b["date"] == target_date), None)
        if not target:
            print(f"[HF] Backup not found: {target_date}")
            print(f"[HF] Available: {[b['date'] for b in backups[:10]]}")
            return False
        backups_to_restore = [target]
        print(f"[HF] Restoring specific date: {target_date}")
    else:
        cutoff_date = datetime.now() - timedelta(days=merge_days)
        backups_to_restore = [b for b in backups if b["date_obj"] >= cutoff_date]
        if not backups_to_restore:
            backups_to_restore = [backups[0]]
            print(f"[HF] No backups in last {merge_days} days; restoring latest: {backups[0]['date']}")
        else:
            print(f"[HF] Restoring last {merge_days} days: {[b['date'] for b in backups_to_restore]}")

    config_path = BASE / "openclaw.json"
    config_backup = None
    if config_path.exists():
        config_backup = config_path.read_text(errors="ignore")
        print("[RESTORE] Backed up current openclaw.json")

    safe_clear_base()

    # Restore oldest to newest; newer files overwrite older files.
    for backup in reversed(backups_to_restore):
        print(f"[HF] Downloading {backup['filename']}...")
        try:
            backup_path = hf_hub_download(
                repo_id=HF_REPO_ID,
                filename=backup["filename"],
                repo_type="dataset",
                token=HF_TOKEN,
            )
            print(f"[HF] Extracting {backup['date']}...")
            safe_extract_tar(Path(backup_path))
            print(f"[HF] Merged: {backup['date']}")
        except Exception as e:
            print(f"[HF] Warning: failed to restore {backup['filename']}: {e}")

    if config_backup is not None:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(config_backup)
        print("[RESTORE] Restored current openclaw.json")

    print(f"[HF] Restore success: {len(backups_to_restore)} backup(s)")
    return True


def backup():
    archive_path = create_archive()

    did_s3 = False
    if is_s3_enabled():
        try:
            backup_to_s3(archive_path)
            did_s3 = True
        except Exception as e:
            print(f"[S3] Backup failed: {e}")

    # Keep HF as fallback/archive if configured.
    try:
        backup_to_hf(archive_path)
    except Exception as e:
        print(f"[HF] Backup failed: {e}")

    if not did_s3 and not HF_REPO_ID:
        print("[BACKUP] No backup target configured. Set S3_* or HF_DATASET/HF_TOKEN.")


def restore(target: str | None = None):
    # If target looks like an S3 key, restore that specific key.
    if target and (target.endswith(".tar.gz") or "/" in target):
        if restore_from_s3(target):
            return True

    # Prefer S3 latest when configured.
    if is_s3_enabled() and restore_from_s3():
        return True

    # Fall back to HF. If target is YYYY-MM-DD, HF restore that date.
    return restore_from_hf(target)


def list_backups():
    print("\n===== S3/R2 backups =====")
    if is_s3_enabled():
        try:
            client = get_s3_client()
            prefix = S3_SNAPSHOT_PREFIX + "/"
            resp = client.list_objects_v2(Bucket=S3_BUCKET, Prefix=prefix, MaxKeys=50)
            contents = resp.get("Contents", [])
            if not contents:
                print("No S3 snapshots found")
            for obj in sorted(contents, key=lambda x: x.get("LastModified"), reverse=True):
                print(f"  {obj['Key']}  {obj.get('Size', 0)} bytes  {obj.get('LastModified')}")
        except Exception as e:
            print(f"S3 list failed: {e}")
    else:
        print("S3 not configured")

    print("\n===== HF Dataset backups =====")
    backups = get_hf_backup_files()
    if not backups:
        print("No HF backups found")
    for b in backups:
        print(f"  {b['date']} - {b['filename']}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  sync.py backup")
        print("  sync.py restore")
        print("  sync.py restore YYYY-MM-DD")
        print("  sync.py restore snapshots/openclaw_YYYY-MM-DD_HH-MM-SS.tar.gz")
        print("  sync.py list")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "backup":
        backup()
    elif cmd == "restore":
        arg = sys.argv[2] if len(sys.argv) > 2 else None
        ok = restore(arg)
        sys.exit(0 if ok else 1)
    elif cmd == "list":
        list_backups()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

#!/usr/bin/env python3
"""
智能备份控制器 - 方案B
- 纯变化检测：检测到变化后5分钟内备份
- 2小时最大间隔保险：超过2小时强制备份
- 180天备份保留
- 避免重复备份（5分钟内不重复触发）
"""

import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
import subprocess
import threading

BASE_DIR = "/home/node/.openclaw"
BACKUP_LOCK_FILE = "/tmp/.backup_in_progress"
LAST_BACKUP_TIME_FILE = "/tmp/.last_backup_timestamp"
MIN_BACKUP_INTERVAL = 300  # 5分钟内不重复备份（秒）
MAX_BACKUP_INTERVAL = 7200  # 2小时最大间隔（秒）

def get_last_backup_time():
    """获取上次备份时间"""
    try:
        if os.path.exists(LAST_BACKUP_TIME_FILE):
            with open(LAST_BACKUP_TIME_FILE, 'r') as f:
                return float(f.read().strip())
    except:
        pass
    return 0

def set_last_backup_time():
    """设置上次备份时间"""
    with open(LAST_BACKUP_TIME_FILE, 'w') as f:
        f.write(str(time.time()))

def get_time_since_last_backup():
    """获取距离上次备份的时间（秒）"""
    last_backup = get_last_backup_time()
    if last_backup == 0:
        return float('inf')  # 从未备份过
    return time.time() - last_backup

def should_backup():
    """检查是否应该备份（避免过于频繁）"""
    return get_time_since_last_backup() >= MIN_BACKUP_INTERVAL

def need_forced_backup():
    """检查是否需要强制备份（超过2小时）"""
    return get_time_since_last_backup() >= MAX_BACKUP_INTERVAL

def has_changes():
    """检查是否有重要变化（5分钟内）"""
    try:
        cutoff = time.time() - 300  # 5分钟
        
        # 检查sessions目录
        sessions_dir = Path(BASE_DIR) / "sessions"
        if sessions_dir.exists():
            for root, dirs, files in os.walk(sessions_dir):
                for file in files:
                    try:
                        if os.path.getmtime(os.path.join(root, file)) > cutoff:
                            return True
                    except:
                        continue
        
        # 检查agents目录（skill安装）
        agents_dir = Path(BASE_DIR) / "agents"
        if agents_dir.exists():
            for agent_dir in agents_dir.iterdir():
                if agent_dir.is_dir():
                    skills_dir = agent_dir / "skills"
                    if skills_dir.exists():
                        for root, dirs, files in os.walk(skills_dir):
                            for file in files:
                                try:
                                    if os.path.getmtime(os.path.join(root, file)) > cutoff:
                                        return True
                                except:
                                    continue
        
        # 检查workspace目录
        workspace_dir = Path(BASE_DIR) / "workspace"
        if workspace_dir.exists():
            for root, dirs, files in os.walk(workspace_dir):
                for file in files:
                    try:
                        if os.path.getmtime(os.path.join(root, file)) > cutoff:
                            return True
                    except:
                        continue
        
        # 检查skills目录（通过webchat/agent安装的skill）
        skills_dir = Path(BASE_DIR) / "skills"
        if skills_dir.exists():
            for root, dirs, files in os.walk(skills_dir):
                for file in files:
                    try:
                        if os.path.getmtime(os.path.join(root, file)) > cutoff:
                            return True
                    except:
                        continue
        
        return False
    except Exception as e:
        print(f"[BACKUP-CONTROL] Error checking changes: {e}")
        return False

def do_backup(reason="change-detected", force=False):
    """执行备份
    
    Args:
        reason: 备份触发原因，用于日志
        force: 是否强制备份（绕过5分钟间隔限制）
    """
    if not force and not should_backup():
        print(f"[BACKUP-CONTROL] Skipping backup, too soon (reason: {reason})")
        return False
    
    # 创建锁文件防止重复执行
    if os.path.exists(BACKUP_LOCK_FILE):
        print(f"[BACKUP-CONTROL] Backup already in progress")
        return False
    
    try:
        with open(BACKUP_LOCK_FILE, 'w') as f:
            f.write(str(time.time()))
        
        print(f"[BACKUP-CONTROL] Starting backup (reason: {reason})...")
        
        result = subprocess.run(
            ["python3", "/home/node/app/sync.py", "backup"],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        if result.returncode == 0:
            set_last_backup_time()
            print(f"[BACKUP-CONTROL] Backup completed successfully")
            return True
        else:
            print(f"[BACKUP-CONTROL] Backup failed: {result.stderr}")
            return False
            
    except Exception as e:
        print(f"[BACKUP-CONTROL] Backup error: {e}")
        return False
    finally:
        try:
            if os.path.exists(BACKUP_LOCK_FILE):
                os.remove(BACKUP_LOCK_FILE)
        except:
            pass

def backup_control_loop():
    """
    主控制循环
    - 每5分钟检查一次
    - 有变化则备份（5分钟内不重复）
    - 超过2小时无备份则强制备份
    """
    print("[BACKUP-CONTROL] Starting backup control loop...")
    print("[BACKUP-CONTROL] Strategy: Change detection + 2-hour max interval")
    print("[BACKUP-CONTROL] Retention: 180 days")
    
    time_since_last = get_time_since_last_backup()
    if time_since_last == float('inf'):
        print("[BACKUP-CONTROL] No previous backup found, will backup on first change or 2-hour mark")
    else:
        print(f"[BACKUP-CONTROL] Time since last backup: {time_since_last/60:.1f} minutes")
    
    # 启动后立即检查一次（如果是新启动）
    if time_since_last == float('inf'):
        print("[BACKUP-CONTROL] First run, checking for immediate backup need...")
        if has_changes():
            do_backup(reason="startup-changes")
    
    while True:
        time.sleep(300)  # 每5分钟检查一次
        
        time_since_last = get_time_since_last_backup()
        
        # 策略1: 检查是否需要强制备份（超过2小时）
        if need_forced_backup():
            print(f"[BACKUP-CONTROL] No backup for {time_since_last/3600:.1f} hours, forcing backup...")
            do_backup(reason="forced-2hour")
            continue
        
        # 策略2: 检查是否有变化
        if has_changes():
            if should_backup():
                print("[BACKUP-CONTROL] Changes detected, triggering backup...")
                do_backup(reason="change-detected")
            else:
                print(f"[BACKUP-CONTROL] Changes detected, but backup too soon ({time_since_last/60:.1f} min ago)")
        else:
            # 只有在快接近2小时时才打印日志
            time_remaining = MAX_BACKUP_INTERVAL - time_since_last
            if time_remaining < 600:  # 如果剩余不到10分钟
                print(f"[BACKUP-CONTROL] No changes. Forced backup in {time_remaining/60:.1f} minutes")
            else:
                print(f"[BACKUP-CONTROL] No changes in last 5 minutes")

def manual_backup():
    """手动触发备份（强制执行，不受5分钟间隔限制）"""
    return do_backup(reason="manual", force=True)

def main():
    """主函数"""
    if len(sys.argv) > 1:
        if sys.argv[1] == "manual":
            if manual_backup():
                print("Manual backup completed")
                sys.exit(0)
            else:
                print("Manual backup failed or skipped")
                sys.exit(1)
        elif sys.argv[1] == "check":
            if has_changes():
                print("Changes detected")
                sys.exit(0)
            else:
                print("No changes")
                sys.exit(1)
        elif sys.argv[1] == "status":
            time_since_last = get_time_since_last_backup()
            if time_since_last == float('inf'):
                print("No previous backup")
            else:
                print(f"Last backup: {time_since_last/60:.1f} minutes ago")
                print(f"Next forced backup: in {(MAX_BACKUP_INTERVAL - time_since_last)/60:.1f} minutes")
                if has_changes():
                    print("Changes detected: Yes")
                else:
                    print("Changes detected: No")
            sys.exit(0)
    else:
        # 启动主控制循环
        backup_control_loop()

if __name__ == "__main__":
    main()
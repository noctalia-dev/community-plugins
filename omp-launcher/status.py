#!/usr/bin/env python3
import os
import json
import time
import subprocess

def get_omp_status():
    home = os.path.expanduser('~')
    sessions_dir = os.path.join(home, '.omp', 'agent', 'sessions')
    
    # 1. Check running omp processes
    running_count = 0
    try:
        p = subprocess.run(["pgrep", "-c", "-f", "node.*/bin/omp|/bin/omp|omp.*--continue"], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip().isdigit():
            running_count = int(p.stdout.strip())
    except Exception:
        pass
        
    # 2. Get most recent project from sessions
    recent_path = None
    recent_mtime = 0
    
    if os.path.isdir(sessions_dir):
        for entry in os.scandir(sessions_dir):
            if not entry.is_dir():
                continue
            slug = entry.name
            if slug == "-tmp":
                real_path = "/tmp"
            elif slug.startswith("-"):
                real_path = os.path.join(home, slug[1:].replace('-', '/'))
                if not os.path.isdir(real_path):
                    parts = slug[1:].split('-')
                    curr = home
                    for part in parts:
                        cand = os.path.join(curr, part)
                        if os.path.isdir(cand):
                            curr = cand
                    real_path = curr
            else:
                real_path = os.path.join(home, slug)

            if os.path.isdir(real_path):
                try:
                    mt = entry.stat().st_mtime
                    if mt > recent_mtime:
                        recent_mtime = mt
                        recent_path = real_path
                except OSError:
                    pass
                    
    if recent_path:
        short_name = os.path.basename(recent_path) or "root"
        display_path = recent_path.replace(home, '~')
        
        diff_sec = max(0, int(time.time() - recent_mtime))
        if diff_sec < 60:
            ago_str = "just now"
        elif diff_sec < 3600:
            ago_str = f"{diff_sec // 60}m ago"
        elif diff_sec < 86400:
            ago_str = f"{diff_sec // 3600}h ago"
        else:
            ago_str = f"{diff_sec // 86400}d ago"
    else:
        short_name = "None"
        display_path = "~"
        ago_str = "never"
        
    status_str = f"{running_count} active" if running_count > 0 else "Idle"
    tooltip_lines = [
        "Oh My Pi (omp) Launcher",
        f"• Status: {status_str}",
        f"• Latest Project: {display_path} ({ago_str})",
        "",
        "Left-click: Pick project to open in OMP",
        f"Middle-click: Resume latest ({short_name})",
        "Right-click: Launch in $HOME (--allow-home)"
    ]
    
    return {
        "running": running_count > 0,
        "running_count": running_count,
        "latest_project": display_path,
        "latest_short": short_name,
        "latest_ago": ago_str,
        "tooltip": "\n".join(tooltip_lines)
    }

if __name__ == '__main__':
    print(json.dumps(get_omp_status()))

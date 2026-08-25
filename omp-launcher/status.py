#!/usr/bin/env python3
import os
import json
import time
import subprocess

def resolve_slug(slug, home):
    if slug == "-tmp" or slug == "tmp":
        return "/tmp"
    if slug == "-" or not slug:
        return home
    
    raw = slug[1:] if slug.startswith("-") else slug
    parts = raw.split("-")
    
    curr = home
    i = 0
    while i < len(parts):
        matched = False
        for j in range(len(parts), i, -1):
            chunk = "-".join(parts[i:j])
            candidate = os.path.join(curr, chunk)
            if os.path.isdir(candidate):
                curr = candidate
                i = j
                matched = True
                break
        if not matched:
            curr = os.path.join(curr, parts[i])
            i += 1
            
    return curr

def get_omp_status():
    home = os.path.expanduser('~')
    sessions_dir = os.path.join(home, '.omp', 'agent', 'sessions')
    
    # 1. Check running omp processes
    running_count = 0
    try:
        p = subprocess.run(["pgrep", "-x", "omp"], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip():
            running_count = len([x for x in p.stdout.strip().splitlines() if x.strip()])
        else:
            p2 = subprocess.run(["pgrep", "-c", "-f", r"(^|/)omp(\s|$)"], capture_output=True, text=True)
            if p2.returncode == 0 and p2.stdout.strip().isdigit():
                running_count = int(p2.stdout.strip())
    except Exception:
        pass
        
    # 2. Get most recent project from sessions
    recent_path = None
    recent_mtime = 0
    
    if os.path.isdir(sessions_dir):
        for entry in os.scandir(sessions_dir):
            if not entry.is_dir():
                continue
            real_path = resolve_slug(entry.name, home)
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

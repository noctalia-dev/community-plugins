#!/usr/bin/env python3
import os
import json
import time
import glob
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

def format_ago(mtime):
    diff = max(0, int(time.time() - mtime))
    if diff < 60:
        return "just now"
    if diff < 3600:
        return f"{diff // 60}m ago"
    if diff < 86400:
        return f"{diff // 3600}h ago"
    return f"{diff // 86400}d ago"

def get_last_jsonl_entry(filepath):
    try:
        with open(filepath, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return None
            f.seek(max(0, size - 8192), 0)
            lines = [l for l in chunk.strip().split('\n') if l.strip()]
            for l in reversed(lines):
                try:
                    return json.loads(l)
                except Exception:
                    continue
    except Exception:
        pass
    return None

def get_omp_status():
    home = os.path.expanduser('~')
    sessions_dir = os.path.join(home, '.omp', 'agent', 'sessions')
    
    # 1. Active Client Sessions from ~/.omp/run/daemons/*/clients/*.json
    active_sessions = []
    seen_pids = set()
    client_files = glob.glob(os.path.join(home, '.omp', 'run', 'daemons', '*', 'clients', '*.json'))
    for cf in client_files:
        try:
            with open(cf, 'r') as f:
                cdata = json.load(f)
                pid = cdata.get("pid")
                pdir = cdata.get("projectDir")
                if pid and pdir and pid not in seen_pids:
                    try:
                        os.kill(pid, 0)
                        seen_pids.add(pid)
                        short = os.path.basename(pdir) if pdir != home else "~"
                        if pdir == "/tmp":
                            short = "/tmp"
                        display_p = pdir.replace(home, '~')
                        active_sessions.append({
                            "pid": pid,
                            "path": pdir,
                            "display": display_p,
                            "short": short
                        })
                    except OSError:
                        pass
        except Exception:
            pass
            
    # Fallback to pgrep
    if not active_sessions:
        try:
            p = subprocess.run(["pgrep", "-x", "omp"], capture_output=True, text=True)
            if p.returncode == 0 and p.stdout.strip():
                for line in p.stdout.strip().splitlines():
                    if line.strip().isdigit():
                        active_sessions.append({
                            "pid": int(line.strip()),
                            "path": home,
                            "display": "~",
                            "short": "omp"
                        })
        except Exception:
            pass

    running_count = len(active_sessions)

    # 2. Find All Recent Session Files & Match Exact File mtimes
    all_jsonls = glob.glob(os.path.join(sessions_dir, '*', '*.jsonl'))
    latest_jsonl_file = None
    latest_file_mtime = 0

    if all_jsonls:
        all_jsonls.sort(key=os.path.getmtime, reverse=True)
        latest_jsonl_file = all_jsonls[0]
        try:
            latest_file_mtime = os.path.getmtime(latest_jsonl_file)
        except OSError:
            pass

    # 3. Dynamic Pulse State Detection (Thinking = Sky Blue, Prompting = Clean White, Idle = Muted)
    pulse = "idle"
    pulse_color = "#94A3B8"
    pulse_label = "Idle"

    if running_count > 0:
        time_since_write = time.time() - latest_file_mtime if latest_file_mtime > 0 else 999
        last_entry = get_last_jsonl_entry(latest_jsonl_file) if latest_jsonl_file else None

        if time_since_write < 6.0:
            pulse = "thinking"
            pulse_color = "#38BDF8"
            pulse_label = "Thinking..."
        elif last_entry:
            custom_type = last_entry.get("customType")
            role = last_entry.get("role") or (last_entry.get("message", {}).get("role") if isinstance(last_entry.get("message"), dict) else None)
            if custom_type == "tool_execution_start" or role == "toolResult":
                pulse = "thinking"
                pulse_color = "#38BDF8"
                pulse_label = "Thinking..."
            else:
                pulse = "prompting"
                pulse_color = "#FFFFFF"
                pulse_label = "Ready for input"
        else:
            pulse = "prompting"
            pulse_color = "#FFFFFF"
            pulse_label = "Ready for input"

    # 4. Recent Workspaces Discovery
    recent_projects = []
    seen_paths = set()
    
    if os.path.isdir(sessions_dir):
        entries = []
        for entry in os.scandir(sessions_dir):
            if not entry.is_dir():
                continue
            rpath = resolve_slug(entry.name, home)
            if os.path.isdir(rpath):
                try:
                    jfiles = glob.glob(os.path.join(entry.path, "*.jsonl"))
                    if jfiles:
                        mt = max(os.path.getmtime(jf) for jf in jfiles)
                    else:
                        mt = entry.stat().st_mtime
                except OSError:
                    mt = 0.0
                entries.append((mt, rpath))
                
        entries.sort(key=lambda x: x[0], reverse=True)
        
        for mt, rpath in entries:
            if rpath in seen_paths:
                continue
            seen_paths.add(rpath)
            short = os.path.basename(rpath) if rpath != home else "~"
            if rpath == "/tmp":
                short = "/tmp"
            display_p = rpath.replace(home, '~')
            recent_projects.append({
                "path": rpath,
                "display": display_p,
                "short": short,
                "ago": format_ago(mt),
                "mtime": mt
            })
            if len(recent_projects) >= 8:
                break

    latest_project = recent_projects[0]["display"] if recent_projects else "~"
    latest_short = recent_projects[0]["short"] if recent_projects else "root"
    latest_ago = recent_projects[0]["ago"] if recent_projects else "never"
    
    tooltip_lines = [
        "Oh My Pi (omp) Launcher",
        f"• Status: {running_count} active ({pulse_label})",
        f"• Latest: {latest_project} ({latest_ago})",
        "",
        "Left-click: Open session panel & project picker",
        f"Middle-click: Resume latest ({latest_short})",
        "Right-click: Launch in $HOME"
    ]

    return {
        "running": running_count > 0,
        "running_count": running_count,
        "pulse": pulse,
        "pulse_color": pulse_color,
        "pulse_label": pulse_label,
        "active_sessions": active_sessions,
        "recent_projects": recent_projects,
        "latest_project": latest_project,
        "latest_short": latest_short,
        "latest_ago": latest_ago,
        "tooltip": "\n".join(tooltip_lines)
    }

if __name__ == '__main__':
    print(json.dumps(get_omp_status()))

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

def session_slug(path, home):
    """Session directory name for a project dir: home-relative, "/" -> "-"."""
    if path == home:
        return "-"
    if path.startswith(home + "/"):
        return "-" + path[len(home) + 1:].replace("/", "-")
    return path.replace("/", "-")

def latest_jsonl(session_dir):
    files = glob.glob(os.path.join(session_dir, "*.jsonl"))
    if not files:
        return None, 0.0
    files.sort(key=os.path.getmtime, reverse=True)
    try:
        return files[0], os.path.getmtime(files[0])
    except OSError:
        return None, 0.0

def session_needs_input(path, home, sessions_dir):
    """True when the project's newest session is idle-waiting for the user."""
    if not os.path.isdir(sessions_dir):
        return False
    session_dir = os.path.join(sessions_dir, session_slug(path, home))
    if not os.path.isdir(session_dir):
        for child in os.scandir(sessions_dir):
            if child.is_dir() and resolve_slug(child.name, home) == path:
                session_dir = child.path
                break
        else:
            return False
    latest, mtime = latest_jsonl(session_dir)
    if latest is None:
        return False
    # Fresh writes mean the agent is still working.
    if time.time() - mtime < 6.0:
        return False
    entry = get_last_jsonl_entry(latest)
    if not entry:
        return True
    custom_type = entry.get("customType")
    message = entry.get("message")
    role = entry.get("role") or (message.get("role") if isinstance(message, dict) else None)
    return not (custom_type == "tool_execution_start" or role == "toolResult")

def get_last_jsonl_entry(filepath):
    try:
        with open(filepath, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return None
            f.seek(max(0, size - 8192), 0)
            chunk = f.read().decode('utf-8', 'replace')
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
                            "short": short,
                            "needs_input": session_needs_input(pdir, home, sessions_dir)
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
                            "short": "omp",
                            "needs_input": session_needs_input(home, home, sessions_dir)
                        })
        except Exception:
            pass

    # 2. Recent Workspaces Discovery
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

    return {
        "needs_input": any(s["needs_input"] for s in active_sessions),
        "active_sessions": active_sessions,
        "recent_projects": recent_projects,
    }

if __name__ == '__main__':
    print(json.dumps(get_omp_status()))

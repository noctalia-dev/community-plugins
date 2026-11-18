#!/usr/bin/env python3
"""Process sampler for the yahya637/process-monitor Noctalia plugin.

Runs until killed and prints one compact JSON object per interval on stdout:

  {"t": ms, "cpu": {...}, "mem": {...}, "gpu": {...},
   "procs": [[pid, name, cpu%, memBytes, gpu%, vramBytes, count, [pids], paused], ...],
   "apps":  [same shape, grouped by name]}

Everything comes from /proc and /sys, so no root and no extra tools:
  CPU  - utime+stime deltas from /proc/<pid>/stat against /proc/stat
  RAM  - RssAnon + RssShmem from /proc/<pid>/status (private memory, so it sums
         sensibly across a group; shared libraries are left out)
  GPU  - DRM fdinfo (/proc/<pid>/fdinfo/<fd>): drm-engine-* busy time and
         drm-total-vram, the same counters nvtop and amdgpu_top read. Only
         readable for your own processes. The machine-wide GPU and VRAM totals
         come from amdgpu's sysfs files, so they are AMD-only.
"""

import json
import os
import sys
import time

INTERVAL = 2.0
LIMIT = 40  # rows kept per metric; the union is sent
FD_RESCAN_SECONDS = 10.0
# Engines that count as "GPU busy" per process, by driver naming: amdgpu
# reports gfx/compute, i915 render/compute. Other drivers fall back to the sum
# of every engine they report (clamped to 100%).
GPU_ENGINE_SETS = (("gfx", "compute"), ("render", "compute"))

PAGE = os.sysconf("SC_PAGE_SIZE")
CLK = os.sysconf("SC_CLK_TCK")
NCPU = os.cpu_count() or 1
MY_UID = os.getuid()
EXIT_READER_GONE = 3  # the wrapper loop stops restarting on this code


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def parse_args(argv):
    global INTERVAL, LIMIT
    it = iter(argv)
    for a in it:
        if a == "--interval":
            INTERVAL = max(0.5, float(next(it)) / 1000.0)
        elif a == "--limit":
            LIMIT = max(5, int(next(it)))


# ── GPU device ──────────────────────────────────────────────────────────────


def find_gpu():
    """Pick the discrete GPU: the DRM card with the most VRAM."""
    best = None
    base = "/sys/class/drm"
    try:
        cards = sorted(n for n in os.listdir(base) if n.startswith("card") and "-" not in n)
    except OSError:
        return None
    for card in cards:
        dev = os.path.join(base, card, "device")
        total = read(os.path.join(dev, "mem_info_vram_total"))
        try:
            total = int(total) if total else 0
        except ValueError:
            total = 0
        pdev = os.path.basename(os.path.realpath(dev))
        cand = {"dev": dev, "pdev": pdev, "vramTotal": total}
        if best is None or total > best["vramTotal"]:
            best = cand
    if best is not None:
        name = None
        uevent = read(os.path.join(best["dev"], "uevent")) or ""
        for line in uevent.splitlines():
            if line.startswith("DRIVER="):
                name = line[7:]
        best["driver"] = name
    return best


def gpu_totals(gpu):
    if gpu is None:
        return None
    out = {"pdev": gpu["pdev"]}
    busy = read(os.path.join(gpu["dev"], "gpu_busy_percent"))
    used = read(os.path.join(gpu["dev"], "mem_info_vram_used"))
    try:
        out["pct"] = float(busy) if busy else None
    except ValueError:
        out["pct"] = None
    try:
        out["vramUsed"] = int(used) if used else None
    except ValueError:
        out["vramUsed"] = None
    out["vramTotal"] = gpu["vramTotal"] or None
    return out


# ── /proc helpers ───────────────────────────────────────────────────────────


def cpu_total_jiffies():
    s = read("/proc/stat")
    if not s:
        return 0, 0
    parts = s.split("\n", 1)[0].split()[1:]
    vals = [int(x) for x in parts[:8]]
    total = sum(vals)
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return total, idle


def meminfo():
    s = read("/proc/meminfo") or ""
    m = {}
    for line in s.splitlines():
        k, _, rest = line.partition(":")
        v = rest.split()
        if v:
            m[k] = int(v[0]) * 1024
    total = m.get("MemTotal", 0)
    avail = m.get("MemAvailable", 0)
    return {
        "used": total - avail,
        "total": total,
        "swapUsed": m.get("SwapTotal", 0) - m.get("SwapFree", 0),
        "swapTotal": m.get("SwapTotal", 0),
    }


def proc_stat(pid):
    s = read(f"/proc/{pid}/stat")
    if not s:
        return None
    # comm can contain spaces and parens; it ends at the last ')'
    r = s.rfind(")")
    comm = s[s.find("(") + 1 : r]
    f = s[r + 2 :].split()
    # f[0]=state f[1]=ppid ... f[11]=utime f[12]=stime f[19]=starttime
    return {
        "comm": comm,
        "stopped": f[0] in ("T", "t"),
        "ppid": int(f[1]),
        "ticks": int(f[11]) + int(f[12]),
        "start": int(f[19]),
    }


def proc_mem(pid):
    s = read(f"/proc/{pid}/status")
    if not s:
        return 0, None
    anon = shmem = 0
    uid = None
    for line in s.splitlines():
        if line.startswith("RssAnon:"):
            anon = int(line.split()[1]) * 1024
        elif line.startswith("RssShmem:"):
            shmem = int(line.split()[1]) * 1024
        elif line.startswith("Uid:"):
            uid = int(line.split()[1])
    return anon + shmem, uid


# Executables that host other programs: group these by process name instead.
GENERIC_EXES = (
    "python", "python3", "node", "java", "bash", "sh", "zsh", "fish", "perl",
    "ruby", "deno", "bwrap", "qemu", "steam-runtime", "pressure-vessel",
)


def app_name(pid, name):
    """Group key: the executable, so a browser's renamed children stay together."""
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return name
    base = exe.rsplit("/", 1)[-1].removesuffix(" (deleted)")
    low = base.lower()
    if (
        not base[:1].isalpha()  # versioned binaries such as .../versions/2.1.318
        or "wine" in low
        or "preloader" in low
        or low.startswith(GENERIC_EXES)
        or low.startswith("ld-linux")
    ):
        return name
    return base


def pretty_name(pid, comm):
    """comm is cut at 15 chars; argv[0] usually has the full name."""
    raw = read(f"/proc/{pid}/cmdline")
    if raw:
        argv0 = raw.split("\0", 1)[0]
        if raw.count("\0") <= 1 and " -" in argv0:
            # Electron/Chromium children rewrite their argv into one string
            # ("/usr/lib/vesktop/vesktop --type=renderer ..."): drop the flags.
            argv0 = argv0.split(" -", 1)[0]
        # Wine/Proton: argv[0] may be a Windows path like Z:\...\Game.exe
        base = argv0.replace("\\", "/").rsplit("/", 1)[-1]
        if base and (base.startswith(comm[:15]) or len(comm) >= 15):
            return base
        # wine preloader / python / etc: prefer a .exe argument if present
        if comm.endswith(".exe") or "wine" in comm or "preloader" in comm:
            for a in raw.split("\0")[1:4]:
                if a.lower().endswith(".exe"):
                    return a.replace("\\", "/").rsplit("/", 1)[-1]
    return comm


# ── DRM fdinfo ──────────────────────────────────────────────────────────────


def scan_drm_fds(pid):
    fds = []
    d = f"/proc/{pid}/fd"
    try:
        for e in os.scandir(d):
            try:
                if os.readlink(e.path).startswith("/dev/dri/"):
                    fds.append(e.name)
            except OSError:
                pass
    except OSError:
        return None
    return fds


def parse_size(v):
    p = v.split()
    n = int(p[0])
    unit = p[1] if len(p) > 1 else ""
    return n * {"KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}.get(unit, 1)


def read_drm(pid, fds, pdev, seen):
    """Sum engine ns and VRAM over this process's distinct DRM clients on pdev."""
    busy = 0
    vram = 0
    found = False
    for fd in fds:
        s = read(f"/proc/{pid}/fdinfo/{fd}")
        if not s or "drm-client-id" not in s:
            continue
        info = {}
        for line in s.splitlines():
            k, _, v = line.partition(":")
            if k.startswith("drm-"):
                info[k] = v.strip()
        if info.get("drm-pdev") != pdev:
            continue
        cid = info.get("drm-client-id")
        if cid in seen:
            continue
        seen.add(cid)
        found = True
        engines = {}
        for k, v in info.items():
            if k.startswith("drm-engine-") and not k.startswith("drm-engine-capacity-"):
                try:
                    engines[k[len("drm-engine-"):]] = int(v.split()[0])
                except (ValueError, IndexError):
                    pass
        for names in GPU_ENGINE_SETS:
            if any(n in engines for n in names):
                busy += sum(engines.get(n, 0) for n in names)
                break
        else:
            busy += sum(engines.values())
        v = info.get("drm-total-vram") or info.get("drm-memory-vram")
        if v:
            try:
                vram += parse_size(v)
            except ValueError:
                pass
    return found, busy, vram


# ── main loop ───────────────────────────────────────────────────────────────


def main():
    parse_args(sys.argv[1:])
    gpu = find_gpu()
    pdev = gpu["pdev"] if gpu else None

    prev_ticks = {}  # (pid, start) -> ticks
    prev_gpu = {}  # (pid, start) -> engine ns
    drm_fds = {}  # (pid, start) -> [fd]  (None = unreadable)
    names = {}  # (pid, start) -> (pretty name, app group name)
    last_rescan = 0.0
    prev_total, _ = cpu_total_jiffies()
    prev_idle = 0
    prev_wall = time.monotonic_ns()
    first = True

    while True:
        now_mono = time.monotonic()
        rescan = now_mono - last_rescan >= FD_RESCAN_SECONDS
        if rescan:
            last_rescan = now_mono

        total, idle = cpu_total_jiffies()
        wall = time.monotonic_ns()
        d_total = max(1, total - prev_total)
        d_idle = idle - prev_idle
        d_wall = max(1, wall - prev_wall)

        rows = []
        alive = set()
        seen_clients = set()
        try:
            pids = sorted(int(p) for p in os.listdir("/proc") if p.isdigit())
        except OSError:
            pids = []
        for pid in pids:
            try:
                st = proc_stat(pid)
            except (ValueError, IndexError):
                st = None  # malformed or vanished mid-read
            if st is None:
                continue
            if st["ppid"] == 2 or pid == 2:
                continue  # kernel threads
            key = (pid, st["start"])
            alive.add(key)

            pt = prev_ticks.get(key)
            prev_ticks[key] = st["ticks"]
            cpu = 0.0 if pt is None else (st["ticks"] - pt) * 100.0 / d_total

            try:
                mem, uid = proc_mem(pid)
            except (ValueError, IndexError):
                mem, uid = 0, None

            gpu_pct = 0.0
            vram = 0
            if pdev is not None and uid == MY_UID:
                fds = drm_fds.get(key, "new")
                if fds == "new" or rescan:
                    fds = scan_drm_fds(pid)
                    drm_fds[key] = fds
                if fds:
                    found, busy, vram = read_drm(pid, fds, pdev, seen_clients)
                    if found:
                        pg = prev_gpu.get(key)
                        prev_gpu[key] = busy
                        if pg is not None and busy >= pg:
                            gpu_pct = min(100.0, (busy - pg) * 100.0 / d_wall)

            nm = names.get(key)
            if nm is None:
                pretty = pretty_name(pid, st["comm"])
                nm = (pretty, app_name(pid, pretty))
                names[key] = nm
            name, app = nm

            rows.append([pid, name, round(cpu, 2), mem, round(gpu_pct, 2), vram, 1, [pid], st["stopped"], app])

        # forget dead processes
        for d in (prev_ticks, prev_gpu, drm_fds, names):
            for k in [k for k in d if k not in alive]:
                del d[k]

        prev_total, prev_idle, prev_wall = total, idle, wall

        if first:
            first = False  # deltas need two samples; don't publish zeros
            time.sleep(min(INTERVAL, 1.0))
            continue

        # group by name
        groups = {}
        for r in rows:
            app = r.pop()  # drop the group key from the per-process row
            g = groups.get(app)
            if g is None:
                groups[app] = [r[0], app, r[2], r[3], r[4], r[5], 1, [r[0]], r[8], r[2] + r[4]]
            else:
                g[2] += r[2]
                g[3] += r[3]
                g[4] = min(100.0, g[4] + r[4])
                g[5] += r[5]
                g[6] += 1
                g[7].append(r[0])
                g[8] = g[8] and r[8]  # paused only if every member is
                # the group's representative pid is its busiest member
                if r[2] + r[4] > g[9]:
                    g[0] = r[0]
                    g[9] = r[2] + r[4]
        apps = []
        for g in groups.values():
            g.pop()
            g[2] = round(g[2], 2)
            g[4] = round(g[4], 2)
            apps.append(g)

        out = {
            "t": int(time.time() * 1000),
            "cpu": {
                "pct": round(max(0.0, 100.0 * (1 - d_idle / d_total)), 1),
                "cores": NCPU,
            },
            "mem": meminfo(),
            "gpu": gpu_totals(gpu),
            "nprocs": len(rows),
            "procs": top_union(rows),
            "apps": top_union(apps),
        }
        try:
            sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(EXIT_READER_GONE)

        elapsed = time.monotonic() - now_mono
        time.sleep(max(0.1, INTERVAL - elapsed))


def top_union(rows):
    keep = {}
    for idx in (2, 3, 4, 5):  # cpu, ram, gpu, vram
        for r in sorted(rows, key=lambda r: r[idx], reverse=True)[:LIMIT]:
            if idx != 3 and r[idx] <= 0:  # ram always fills its quota
                break
            keep[id(r)] = r
    return list(keep.values())


def die_with_parent():
    """Exit when the wrapper shell that Noctalia started goes away."""
    try:
        import ctypes
        import signal

        libc = ctypes.CDLL(None, use_errno=True)
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
        if os.getppid() == 1:
            os._exit(EXIT_READER_GONE)
    except Exception:
        pass


if __name__ == "__main__":
    die_with_parent()
    try:
        main()
    except KeyboardInterrupt:
        pass

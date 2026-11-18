import subprocess
import os
import sys
import errno
import json
import traceback

import draw_graph

self_pid = os.getpid()
g_process = None

# The following exits cleanly on Ctrl-C or EPIPE
# while treating other exceptions as before.
def std_exceptions(etype, value, tb):
    sys.excepthook = sys.__excepthook__
    save_path = os.environ.get("XDG_RUNTIME_DIR", "/dev/shm")
    if os.path.exists(f"{save_path}/noctalia_tordex_nvtop.json"):
        os.remove(f"{save_path}/noctalia_tordex_nvtop.json")

    if g_process is not None:
        g_process.terminate()
    if issubclass(etype, KeyboardInterrupt) or issubclass(etype, IOError) and value.errno == errno.EPIPE:
        print("tordex/nvtop:done:" + json.dumps({"status": "ok", "message": "Interrupted by user"}))
    else:
        tb_lines = traceback.format_exception(value)
        print("tordex/nvtop:done:" + json.dumps({"status": "error", "message": "".join(tb_lines)}))


sys.excepthook = std_exceptions


def nofollow_opener(path, flags):
    return os.open(path, flags | os.O_NOFOLLOW)


g_params_file = os.environ.get("XDG_RUNTIME_DIR", "/dev/shm") + "/noctalia_tordex_nvtop_params"
g_selected_gpu = 1


def read_params():
    global g_params_file, g_selected_gpu

    try:
        with open(g_params_file, "r") as f:
            g_selected_gpu = int(f.readline().strip())
    except FileNotFoundError:
        g_selected_gpu = 1

def to_int(value, default=0):
    try:
        return int(value)
    except (ValueError, TypeError):
        return default

def process_buffer(buffer, skin):
    global g_selected_gpu

    save_path = os.environ.get("XDG_RUNTIME_DIR", "/dev/shm")
    output_path = os.path.join(save_path, "noctalia_tordex_nvtop.json")

    read_params()
    data = json.loads("".join(buffer))

    gpu_graph_path = f"{save_path}/noctalia_tordex_nvtop_gpu_usage.png"
    mem_graph_path = f"{save_path}/noctalia_tordex_nvtop_mem_usage.png"

    if g_selected_gpu < 1 or g_selected_gpu > len(data):
        g_selected_gpu = 1

    # Draw GPU usage graph
    if data[g_selected_gpu - 1] is None:
        gpu_load = 0
        gpu_load_val_text = "N/A"
    else:
        gpu_load = to_int(data[g_selected_gpu - 1]["gpu_util"][:-1])
        gpu_load_val_text = f"{gpu_load}%"

    if data[g_selected_gpu - 1]["temp"] is None:
        gpu_temp = "N/A"
    else:
        gpu_temp = data[g_selected_gpu - 1]["temp"]

    ret = draw_graph.draw_graph(
        percent=gpu_load,
        val_text=gpu_load_val_text,
        label_text="GPU",
        sub_text=f"{gpu_temp}",
        skin=skin,
        filename=gpu_graph_path)
    if not ret:
        gpu_graph_path = None

    # Draw VRAM usage graph
    if data[g_selected_gpu - 1]["mem_used"] is None or data[g_selected_gpu - 1]["mem_total"] is None:
        mem_used = 0
        mem_total = 0
        mem_val_text = "N/A"
        mem_sub_text = "N/A"
        mem_percent = 0
    else:
        mem_used = to_int(data[g_selected_gpu - 1]["mem_used"])
        mem_total = to_int(data[g_selected_gpu - 1]["mem_total"])
        mem_val_text = f"{round(mem_used / (1024 * 1024 * 1024), 1)}G"
        mem_sub_text = f"+{round((mem_total - mem_used) / (1024 * 1024 * 1024), 1)}G"
        mem_percent = int(mem_used / mem_total * 100)

    ret = draw_graph.draw_graph(
        percent=mem_percent,
        val_text=mem_val_text,
        label_text="VRAM",
        sub_text=mem_sub_text,
        skin=skin,
        filename=mem_graph_path
    )
    if not ret:
        mem_graph_path = None

    with open(output_path, "w", opener=nofollow_opener) as output_file:
        output_file.writelines(buffer)

    out = {
        "data": output_path,
        "gpu_graph": gpu_graph_path,
        "mem_graph": mem_graph_path,
    }

    print(f"tordex/nvtop:ready:{json.dumps(out)}", flush=True)


def run_process(command):
    try:
        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            text=True
        )
        stdout, _ = proc.communicate()
        return stdout.splitlines()
    except Exception as e:
        return []


def main():
    global g_process

    interval = (int)(sys.argv[1]) if len(sys.argv) > 1 else 5
    skin = sys.argv[2] if len(sys.argv) > 2 else "dark"

    # First run to get the initial state
    buffer = run_process(["nvtop", "-s"])
    process_buffer(buffer, skin)

    g_process = subprocess.Popen(
        ["nvtop", "-l", "-d", str(interval)],
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    buffer = None
    for line in g_process.stdout:
        if line == "[\n":
            buffer = [line]
        elif buffer is not None:
            buffer.append(line)
            if line == "]\n":
                process_buffer(buffer, skin)
                buffer = None

    g_process.wait()

if __name__ == '__main__':
    print(f"tordex/nvtop:pid:{self_pid}")
    main()
    print("tordex/nvtop:done:" + json.dumps({"status": "ok", "message": "Finished"}))

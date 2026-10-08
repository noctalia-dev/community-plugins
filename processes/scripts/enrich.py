import sys
import json
import proc

proc = proc.Proc()

pid = (int)(sys.argv[1]) if len(sys.argv) > 1 else -1

if pid == -1:
    sys.exit(1)

exe = proc.get_exe(pid)
cmdline = proc.get_cmdline(pid)
comm = proc.get_name(pid)

if exe is None:
    if len(cmdline) > 0:
        exe = cmdline[0]

cmdline = " ".join(cmdline) if cmdline else ""

output = {
    "exe": exe,
    "cmdline": cmdline,
    "comm": comm
}

print(json.dumps(output))

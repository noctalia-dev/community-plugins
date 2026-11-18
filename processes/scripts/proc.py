import os
import sys
import errno

PAGESIZE = os.sysconf("SC_PAGE_SIZE") / 1024 #KiB

class Proc:
    def __init__(self):
        uname = os.uname()
        if uname[0] == "FreeBSD":
            self.proc = '/compat/linux/proc'
        else:
            self.proc = '/proc'

    def path(self, *args):
        return os.path.join(self.proc, *(str(a) for a in args))

    def open(self, *args):
        try:
            return open(self.path(*args), errors='ignore')
        except OSError:
            if type(args[0]) is not int:
                raise
            val = sys.exc_info()[1]
            if (val.errno == errno.ENOENT or # kernel thread or process gone
                val.errno == errno.EPERM or
                val.errno == errno.EACCES):
                raise LookupError
            raise

    def get_exe(self, pid):
        path = self.path(pid, 'exe')
        try:
            path = os.readlink(path)
            # Some symlink targets were seen to contain NULs on RHEL 5 at least
            path = path.split('\0')[0]
        except OSError:
            return None
        return path

    def get_cmdline(self, pid):
        try:
            with self.open(pid, 'cmdline') as f:
                cmdline = f.read().split("\0")
                while cmdline[-1] == '' and len(cmdline) > 1:
                    cmdline = cmdline[:-1]
                return cmdline
        except LookupError:
            return []

    def get_name(self, pid):
        try:
            with self.open(pid, 'comm') as f:
                name = f.read().strip()
                return name
        except LookupError:
            return None

    def get_mem_stats(self, pid):
        have_swap_pss = False
        have_pss = False
        private_lines = []
        shared_lines = []
        pss_lines = []
        rss = (int(self.open(pid, 'statm').readline().split()[1]) * PAGESIZE)
        swap_lines = []
        swap_pss_lines = []

        swap = 0

        try:
            if os.path.exists(self.path(pid, 'smaps')):  # stat
                smaps = 'smaps'
                if os.path.exists(self.path(pid, 'smaps_rollup')):
                    smaps = 'smaps_rollup' # faster to process
                lines = self.open(pid, smaps).readlines()  # open
                for line in lines:
                    if line.startswith("Shared"):
                        shared_lines.append(line)
                    elif line.startswith("Private"):
                        private_lines.append(line)
                    elif line.startswith("Pss:"):
                        pss_lines.append(line)
                        have_pss = True
                    elif line.startswith("Swap:"):
                        swap_lines.append(line)
                    elif line.startswith("SwapPss:"):
                        have_swap_pss = True
                        swap_pss_lines.append(line)

                shared = sum([int(line.split()[1]) for line in shared_lines])
                private = sum([int(line.split()[1]) for line in private_lines])
                if have_pss:
                    pss_adjust = 0.5 # add 0.5KiB as this avg error due to truncation
                    pss = sum([float(line.split()[1])+pss_adjust for line in pss_lines])
                    shared = pss - private
                if have_swap_pss:
                    swap = sum([int(line.split()[1]) for line in swap_pss_lines])
                else:
                    swap = sum([int(line.split()[1]) for line in swap_lines])
            else:
                shared = int(self.open(pid, 'statm').readline().split()[2])
                shared *= PAGESIZE
                private = rss - shared
                swap = 0

            return {
                "private": int(private * 1024),
                "shared": int(shared * 1024),
                "swap": int(swap * 1024),
                "mem": int((private + shared) * 1024)
            }
        except (LookupError, ProcessLookupError):
            shared = int(self.open(pid, 'statm').readline().split()[2])
            shared *= PAGESIZE
            private = rss - shared
            return {
                "private": int(private * 1024),
                "shared": int(shared * 1024),
                "swap": int(swap * 1024),
                "mem": int(private * 1024)
            }

    def get_cpu_ticks(self, pid: int):
        """Reads the system's total CPU time and the specific process's ticks."""
        try:
            # 1. System time (the first line of /proc/stat: user, nice, system, idle, ...)
            with self.open("stat") as f:
                fields = f.readline().split()[1:]
                total_system_ticks = sum(int(x) for x in fields)

            # 2. Process time (the 14th and 15th fields in /proc/<pid>/stat: utime and stime)
            with self.open(pid, "stat") as f:
                stat_content = f.read()
                # The process name field (comm) may contain spaces and parentheses,
                # so parse everything strictly after the last closing parenthesis ')'
                post_comm = stat_content[stat_content.rfind(")") + 2 :].split()
                utime = int(post_comm[11])  # field 14 (index 11)
                stime = int(post_comm[12])  # field 15 (index 12)
                proc_ticks = utime + stime
                return {
                    "system_ticks": total_system_ticks,
                    "ticks": proc_ticks
                }
        except (LookupError, ProcessLookupError) as e:
            return {
                "system_ticks": None,
                "ticks": None
            }

    def get_uid(self, pid: int):
        """Reads the user ID (UID) of the specific process."""
        try:
            with self.open(pid, "status") as f:
                for line in f:
                    if line.startswith("Uid:"):
                        return int(line.split()[1])
            return -1
        except (LookupError, ProcessLookupError) as e:
            return -1

    def get_ppid(self, pid: int):
        """Reads the parent process ID (PPID) of the specific process."""
        try:
            with self.open(pid, "stat") as f:
                stat_content = f.read()
                # The process name field (comm) may contain spaces and parentheses,
                # so parse everything strictly after the last closing parenthesis ')'
                post_comm = stat_content[stat_content.rfind(")") + 2 :].split()
                return int(post_comm[1])  # field 4 (index 1)
        except (LookupError, ProcessLookupError) as e:
            return None

    def get_io_bytes(self, pid: int):
        """Reads disk read and write bytes from /proc/<pid>/io."""
        try:
            read_b, write_b = 0, 0
            with self.open(pid, "io") as f:
                for line in f:
                    if line.startswith("read_bytes:"):
                        read_b = int(line.split()[1])
                    elif line.startswith("write_bytes:"):
                        write_b = int(line.split()[1])
            return {
                "read_b": read_b,
                "write_b": write_b
            }
        except (LookupError, ProcessLookupError, PermissionError):
            return {
                "read_b": 0,
                "write_b": 0
            }

    def get_cpu_times(self):
        try:
            with self.open("stat") as f:
                fields = [int(column) for column in f.readline().strip().split()[1:]]
            idle_time = fields[3] + fields[4]  # idle + iowait
            total_time = sum(fields)
            return idle_time, total_time
        except LookupError:
            return None, None

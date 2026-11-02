"""`Command`, the child it starts, and what comes back.

A child starts through one path on both platforms (DESIGN.md, "How a child
starts"): the parent prepares every buffer, `fork`s, and the child makes only
async-signal-safe calls before it execs. On Linux that ends in `execve`; on
macOS it ends in `posix_spawn` with `POSIX_SPAWN_SETEXEC`, which execs in
place and closes every descriptor not named in its file actions, since macOS
has no `close_range`.
"""

from std.ffi import c_int, c_short, c_size_t, c_ssize_t, c_uint, external_call
from std.memory import stack_allocation

from ._libc import (
    IS_LINUX,
    NSIG,
    POLLERR,
    POLLHUP,
    POLLIN,
    POSIX_SPAWN_CLOEXEC_DEFAULT,
    POSIX_SPAWN_SETEXEC,
    POSIX_SPAWN_SETSIGDEF,
    POSIX_SPAWN_SETSIGMASK,
    RLIMIT_CPU,
    RLIMIT_FSIZE,
    RLIMIT_NOFILE,
    SIGACTION_BYTES,
    SIGKILL,
    SIGSET_BYTES,
    SIGTERM,
    SIG_SETMASK,
    SYS_CLOSE_RANGE,
    WNOHANG,
    addr_of,
    close_fd,
    cp,
    current_environment,
    describe_errno,
    errno,
    fork,
    is_executable,
    kill_group,
    monotonic_ns,
    open_append,
    open_null,
    open_read,
    pipe_cloexec,
    poll_fds,
    read_i32,
    read_u64,
    read_some,
    setpgid,
    sleep_ms,
    waitpid,
    write_u64,
)


# ── Stdio ───────────────────────────────────────────────────────────────────


@fieldwise_init
struct Stdio(Copyable, Movable):
    """Where one of a child's standard streams goes."""

    var kind: Int
    var path: String

    comptime INHERIT = 0
    comptime NULL = 1
    comptime CAPTURE = 2
    comptime FILE = 3

    @staticmethod
    def inherit() -> Stdio:
        """The parent's own descriptor."""
        return Stdio(Self.INHERIT, String())

    @staticmethod
    def null() -> Stdio:
        """`/dev/null`."""
        return Stdio(Self.NULL, String())

    @staticmethod
    def capture() -> Stdio:
        """A pipe the parent reads into `Output` (stdout and stderr only)."""
        return Stdio(Self.CAPTURE, String())

    @staticmethod
    def file(path: String) -> Stdio:
        """A file: appended to (created 0644) for output, read for stdin."""
        return Stdio(Self.FILE, path)


# ── Limits ──────────────────────────────────────────────────────────────────


struct Limits(Copyable, Movable):
    """Resource limits set with `setrlimit` in the child. -1 leaves one unset.

    There's no memory limit: see DESIGN.md, "Memory limits".
    """

    var cpu_seconds: Int
    var open_files: Int
    var file_size_bytes: Int

    def __init__(out self):
        self.cpu_seconds = -1
        self.open_files = -1
        self.file_size_bytes = -1


# ── ExitStatus and Output ───────────────────────────────────────────────────


@fieldwise_init
struct ExitStatus(Copyable, Movable, Writable):
    """How a child ended: exited with a code, killed by a signal, or timed out.
    """

    var kind: Int
    var value: Int

    comptime EXITED = 0
    comptime SIGNALED = 1
    comptime TIMED_OUT = 2

    @staticmethod
    def from_wait(raw: Int) -> ExitStatus:
        var low = raw & 0x7F
        if low == 0:
            return ExitStatus(Self.EXITED, (raw >> 8) & 0xFF)
        return ExitStatus(Self.SIGNALED, low)

    def success(self) -> Bool:
        return self.kind == Self.EXITED and self.value == 0

    def exited(self) -> Bool:
        return self.kind == Self.EXITED

    def timed_out(self) -> Bool:
        return self.kind == Self.TIMED_OUT

    def code(self) -> Int:
        """The exit code, or -1 if the child didn't exit by itself."""
        return self.value if self.kind == Self.EXITED else -1

    def signal(self) -> Int:
        """The signal that killed the child, or 0."""
        return self.value if self.kind == Self.SIGNALED else 0

    def write_to(self, mut writer: Some[Writer]):
        if self.kind == Self.EXITED:
            writer.write("exited ", self.value)
        elif self.kind == Self.SIGNALED:
            writer.write("killed by signal ", self.value)
        else:
            writer.write("timed out")


struct Output(Movable):
    """What `Command.run()` and `Child.wait()` return."""

    var status: ExitStatus
    var stdout: List[UInt8]
    var stderr: List[UInt8]
    var stdout_truncated: Bool
    var stderr_truncated: Bool
    var wall_ns: Int

    def __init__(
        out self,
        status: ExitStatus,
        var stdout: List[UInt8],
        var stderr: List[UInt8],
        stdout_truncated: Bool,
        stderr_truncated: Bool,
        wall_ns: Int,
    ):
        self.status = status.copy()
        self.stdout = stdout^
        self.stderr = stderr^
        self.stdout_truncated = stdout_truncated
        self.stderr_truncated = stderr_truncated
        self.wall_ns = wall_ns

    def stdout_text(self) -> String:
        return String(from_utf8_lossy=Span(self.stdout))

    def stderr_text(self) -> String:
        return String(from_utf8_lossy=Span(self.stderr))


struct _Capture(Movable):
    """Keeps the first and last `limit / 2` bytes of a stream."""

    var head: List[UInt8]
    var tail: List[UInt8]
    var tail_start: Int
    var half: Int
    var total: Int

    def __init__(out self, limit: Int):
        self.head = List[UInt8]()
        self.tail = List[UInt8]()
        self.tail_start = 0
        self.half = max(limit // 2, 1)
        self.total = 0

    def add(mut self, buf: List[UInt8], n: Int):
        self.total += n
        var i = 0
        while i < n and len(self.head) < self.half:
            self.head.append(buf[i])
            i += 1
        while i < n:
            self.tail.append(buf[i])
            i += 1
        var live = len(self.tail) - self.tail_start
        if live > self.half:
            self.tail_start += live - self.half
        if self.tail_start > self.half:
            var kept = List[UInt8](capacity=len(self.tail) - self.tail_start)
            for j in range(self.tail_start, len(self.tail)):
                kept.append(self.tail[j])
            self.tail = kept^
            self.tail_start = 0

    def take(mut self) -> List[UInt8]:
        var out = self.head^
        self.head = List[UInt8]()
        for j in range(self.tail_start, len(self.tail)):
            out.append(self.tail[j])
        return out^

    def truncated(self) -> Bool:
        return self.total > len(self.head) + len(self.tail) - self.tail_start


# ── C strings for the child ─────────────────────────────────────────────────


struct _CStrings(Movable):
    """NUL-terminated strings in one buffer, and a NULL-terminated array of
    pointers into it, built before `fork` so the child allocates nothing."""

    var bytes: List[UInt8]
    var offsets: List[Int]
    var ptrs: List[UInt8]

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.offsets = List[Int]()
        self.ptrs = List[UInt8]()

    def add(mut self, s: String):
        self.offsets.append(len(self.bytes))
        var sp = s.as_bytes()
        for i in range(len(sp)):
            self.bytes.append(sp[i])
        self.bytes.append(0)

    def finish(mut self) -> Int:
        """Fixes the buffer and returns the address of the pointer array."""
        if len(self.bytes) == 0:
            self.bytes.append(0)
        var base = addr_of(self.bytes)
        self.ptrs = List[UInt8](length=(len(self.offsets) + 1) * 8, fill=0)
        var p = addr_of(self.ptrs)
        for i in range(len(self.offsets)):
            write_u64(p + i * 8, UInt64(base + self.offsets[i]))
        return p

    def at(mut self, i: Int) -> Int:
        return addr_of(self.bytes) + self.offsets[i]


# Steps the child reports through the error pipe.
comptime _STEP_SETPGID = 1
comptime _STEP_STDIN = 2
comptime _STEP_STDOUT = 3
comptime _STEP_STDERR = 4
comptime _STEP_CHDIR = 5
comptime _STEP_RLIMIT = 6
comptime _STEP_SIGNALS = 7
comptime _STEP_CLOSE = 8
comptime _STEP_EXEC = 9


def _step_name(step: Int) -> String:
    if step == _STEP_SETPGID:
        return "setpgid"
    if step == _STEP_STDIN:
        return "redirect stdin"
    if step == _STEP_STDOUT:
        return "redirect stdout"
    if step == _STEP_STDERR:
        return "redirect stderr"
    if step == _STEP_CHDIR:
        return "chdir"
    if step == _STEP_RLIMIT:
        return "setrlimit"
    if step == _STEP_SIGNALS:
        return "reset signals"
    if step == _STEP_CLOSE:
        return "close descriptors"
    if step == _STEP_EXEC:
        return "exec"
    return String("step ", step)


@fieldwise_init
struct _ChildPlan(ImplicitlyCopyable, Movable):
    """Everything the child needs, as plain integers and addresses."""

    var path: Int
    var argv: Int
    var envp: Int
    var cwd: Int  # 0: stay
    var fd_in: c_int  # -1: inherit
    var fd_out: c_int
    var fd_err: c_int
    var err_w: c_int
    var rlimits: Int  # address of (resource, value) Int64 pairs
    var n_rlimits: Int
    var zeros: Int  # SIGACTION_BYTES zero bytes
    var spawn_attr: Int  # macOS: posix_spawnattr_t*
    var spawn_actions: Int  # macOS: posix_spawn_file_actions_t*


def _child_fail(err_w: c_int, step: Int, code: c_int):
    var msg = stack_allocation[2, Int32]()
    msg.unsafe_write(Int32(step))
    msg.unsafe_offset(1).unsafe_write(Int32(code))
    _ = external_call["write", c_ssize_t](err_w, msg, c_size_t(8))
    external_call["_exit", NoneType](c_int(127))


def _child_main(plan: _ChildPlan):
    """Runs in the forked child. Async-signal-safe calls only; no allocation."""
    if external_call["setpgid", c_int](c_int(0), c_int(0)) != 0:
        _child_fail(plan.err_w, _STEP_SETPGID, errno())
    # dup2 here on both platforms. On macOS, posix_spawn's dup2 file action
    # fails with EBADF under SETEXEC when the source is close-on-exec, which
    # all of ours are: the kernel closes those before it runs the actions.
    if plan.fd_in >= 0:
        if external_call["dup2", c_int](plan.fd_in, c_int(0)) < 0:
            _child_fail(plan.err_w, _STEP_STDIN, errno())
    if plan.fd_out >= 0:
        if external_call["dup2", c_int](plan.fd_out, c_int(1)) < 0:
            _child_fail(plan.err_w, _STEP_STDOUT, errno())
    if plan.fd_err >= 0:
        if external_call["dup2", c_int](plan.fd_err, c_int(2)) < 0:
            _child_fail(plan.err_w, _STEP_STDERR, errno())
    if plan.cwd != 0:
        if external_call["chdir", c_int](cp(plan.cwd)) != 0:
            _child_fail(plan.err_w, _STEP_CHDIR, errno())
    for i in range(plan.n_rlimits):
        var at = plan.rlimits + i * 16
        var lim = stack_allocation[2, UInt64]()
        var v = read_u64(at + 8)
        lim.unsafe_write(v)
        lim.unsafe_offset(1).unsafe_write(v)
        if external_call["setrlimit", c_int](c_int(read_i32(at)), lim) != 0:
            _child_fail(plan.err_w, _STEP_RLIMIT, errno())

    comptime if IS_LINUX:
        # Unblock every signal and put every disposition back to default:
        # SIG_IGN survives exec, and the Mojo runtime ignores some.
        if (
            external_call["sigprocmask", c_int](
                SIG_SETMASK, cp(plan.zeros), cp(0)
            )
            != 0
        ):
            _child_fail(plan.err_w, _STEP_SIGNALS, errno())
        for s in range(1, NSIG):
            _ = external_call["sigaction", c_int](
                c_int(s), cp(plan.zeros), cp(0)
            )
        # Close everything from 3 up except the error pipe, which is
        # close-on-exec and so closes itself when execve succeeds.
        var e = Int(plan.err_w)
        var ok = True
        if e > 3:
            ok = (
                external_call["syscall", Int](
                    SYS_CLOSE_RANGE, c_uint(3), c_uint(e - 1), c_uint(0)
                )
                == 0
            )
        if ok:
            ok = (
                external_call["syscall", Int](
                    SYS_CLOSE_RANGE,
                    c_uint(e + 1),
                    c_uint(0xFFFFFFFF),
                    c_uint(0),
                )
                == 0
            )
        if not ok:
            # Kernels before 5.9: close what an ordinary limit allows.
            for fd in range(3, 65536):
                if fd != e:
                    _ = external_call["close", c_int](c_int(fd))
        _ = external_call["execve", c_int](
            cp(plan.path), cp(plan.argv), cp(plan.envp)
        )
        _child_fail(plan.err_w, _STEP_EXEC, errno())
    else:
        # SETEXEC execs in place; CLOEXEC_DEFAULT closes every descriptor
        # but 0, 1 and 2 (the file actions); the attributes reset signals.
        var pid = stack_allocation[1, c_int]()
        var rc = external_call["posix_spawn", c_int](
            pid,
            cp(plan.path),
            cp(plan.spawn_actions),
            cp(plan.spawn_attr),
            cp(plan.argv),
            cp(plan.envp),
        )
        _child_fail(plan.err_w, _STEP_EXEC, rc)


struct _Fds(Movable):
    """Descriptors closed when this goes away, unless `take`n first."""

    var fds: List[c_int]

    def __init__(out self):
        self.fds = List[c_int]()

    def add(mut self, fd: c_int) -> c_int:
        if fd >= 0:
            self.fds.append(fd)
        return fd

    def take(mut self, fd: c_int) -> c_int:
        """Stops tracking `fd`; the caller owns it now."""
        for i in range(len(self.fds)):
            if self.fds[i] == fd:
                _ = self.fds.pop(i)
                break
        return fd

    def close_all(mut self):
        for fd in self.fds:
            close_fd(fd)
        self.fds.clear()

    def __deinit__(deinit self):
        for fd in self.fds:
            close_fd(fd)


struct _SpawnAttrs(Movable):
    """macOS: a posix_spawnattr_t and file actions, destroyed with this.

    Each is an opaque pointer that `_init` writes into an 8-byte buffer; the
    buffers' addresses are what posix_spawn takes.
    """

    var attr: List[UInt8]
    var actions: List[UInt8]
    var ready: Bool

    def __init__(out self) raises:
        self.attr = List[UInt8](length=8, fill=0)
        self.actions = List[UInt8](length=8, fill=0)
        self.ready = False
        comptime if not IS_LINUX:
            var a = addr_of(self.attr)
            var f = addr_of(self.actions)
            if external_call["posix_spawnattr_init", c_int](cp(a)) != 0:
                raise Error("posix_spawnattr_init: ", describe_errno(errno()))
            if (
                external_call["posix_spawn_file_actions_init", c_int](cp(f))
                != 0
            ):
                _ = external_call["posix_spawnattr_destroy", c_int](cp(a))
                raise Error(
                    "posix_spawn_file_actions_init: ", describe_errno(errno())
                )
            self.ready = True
            var flags = (
                POSIX_SPAWN_SETEXEC
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
            )
            _ = external_call["posix_spawnattr_setflags", c_int](cp(a), flags)
            var sigs = List[UInt8](length=SIGSET_BYTES, fill=0xFF)
            _ = external_call["posix_spawnattr_setsigdefault", c_int](
                cp(a), cp(addr_of(sigs))
            )
            for i in range(SIGSET_BYTES):
                sigs[i] = 0
            _ = external_call["posix_spawnattr_setsigmask", c_int](
                cp(a), cp(addr_of(sigs))
            )
            _ = sigs^
            for fd in range(3):
                var rc = external_call[
                    "posix_spawn_file_actions_addinherit_np", c_int
                ](cp(f), c_int(fd))
                if rc != 0:
                    raise Error(
                        "posix_spawn file actions: ", describe_errno(rc)
                    )

    def attr_addr(mut self) -> Int:
        return addr_of(self.attr)

    def actions_addr(mut self) -> Int:
        return addr_of(self.actions)

    def __deinit__(deinit self):
        comptime if not IS_LINUX:
            if self.ready:
                _ = external_call["posix_spawnattr_destroy", c_int](
                    cp(addr_of(self.attr))
                )
                _ = external_call["posix_spawn_file_actions_destroy", c_int](
                    cp(addr_of(self.actions))
                )
        # In a `deinit` method each field is destroyed after its last use;
        # these keep both buffers alive through the calls above.
        _ = self.attr^
        _ = self.actions^


# ── Child ───────────────────────────────────────────────────────────────────


struct Child(Movable):
    """A running child, the leader of its own process group."""

    var pid: Int
    var _out_fd: c_int
    var _err_fd: c_int
    var _deadline_ns: Int
    var _grace_ms: Int
    var _limit: Int
    var _started_ns: Int
    var _reaped: Bool
    var _status: ExitStatus

    def __init__(
        out self,
        pid: Int,
        out_fd: c_int,
        err_fd: c_int,
        timeout_ns: Int,
        grace_ms: Int,
        limit: Int,
        started_ns: Int,
    ):
        self.pid = pid
        self._out_fd = out_fd
        self._err_fd = err_fd
        self._deadline_ns = started_ns + timeout_ns if timeout_ns >= 0 else -1
        self._grace_ms = grace_ms
        self._limit = limit
        self._started_ns = started_ns
        self._reaped = False
        self._status = ExitStatus(ExitStatus.EXITED, 0)

    def __deinit__(deinit self):
        close_fd(self._out_fd)
        close_fd(self._err_fd)

    def _remaining_ms(self) -> Int:
        if self._deadline_ns < 0:
            return -1
        var left = self._deadline_ns - monotonic_ns()
        if left <= 0:
            return 0
        return (left + 999_999) // 1_000_000

    def _reap(mut self, raw: Int):
        self._reaped = True
        self._status = ExitStatus.from_wait(raw)

    def try_wait(mut self) raises -> Optional[ExitStatus]:
        """The status if the child has ended, without blocking.

        With captured output, use `wait()` instead: a child that fills its
        pipe stops until someone reads it.
        """
        if self._reaped:
            return self._status.copy()
        var r = waitpid(self.pid, WNOHANG)
        if r[0] == self.pid:
            self._reap(r[1])
            return self._status.copy()
        return None

    def kill(mut self) raises:
        """SIGKILLs the child's process group and reaps the child."""
        kill_group(self.pid, SIGKILL)
        if not self._reaped:
            var r = waitpid(self.pid, 0)
            self._reap(r[1])

    def _terminate(mut self) raises:
        """SIGTERM to the group, a grace period, then SIGKILL to the group."""
        kill_group(self.pid, SIGTERM)
        var until = monotonic_ns() + self._grace_ms * 1_000_000
        var pause = 1
        while not self._reaped and monotonic_ns() < until:
            var r = waitpid(self.pid, WNOHANG)
            if r[0] == self.pid:
                self._reap(r[1])
                break
            sleep_ms(pause)
            pause = min(pause * 2, 50)
        # Always, even when the leader went quietly: its group may not have.
        kill_group(self.pid, SIGKILL)
        if not self._reaped:
            var r = waitpid(self.pid, 0)
            self._reap(r[1])
        self._status = ExitStatus(ExitStatus.TIMED_OUT, 0)

    def wait(mut self) raises -> Output:
        """Reads captured output until the child closes it, waits for the
        child to exit, and returns what happened. Stops the child's group at
        the deadline, if there is one."""
        var out_cap = _Capture(self._limit)
        var err_cap = _Capture(self._limit)
        var fds = List[c_int]()
        var which = List[Int]()  # 1: stdout, 2: stderr
        if self._out_fd >= 0:
            fds.append(self._out_fd)
            which.append(1)
        if self._err_fd >= 0:
            fds.append(self._err_fd)
            which.append(2)
        var buf = List[UInt8](length=65536, fill=0)
        var timed_out = False
        var drain_until = -1

        while len(fds) > 0:
            var wait_ms = self._remaining_ms()
            if drain_until >= 0:
                var left = (drain_until - monotonic_ns()) // 1_000_000
                if left <= 0:
                    break
                wait_ms = Int(left)
            elif wait_ms == 0:
                timed_out = True
                self._terminate()
                # A grandchild that left the group could hold a pipe open
                # forever: read what's left for at most a second.
                drain_until = monotonic_ns() + 1_000_000_000
                continue
            var rev = poll_fds(fds, wait_ms)
            var i = len(fds) - 1
            while i >= 0:
                if (rev[i] & (POLLIN | POLLHUP | POLLERR)) != 0:
                    var n = read_some(fds[i], buf)
                    if n == 0:
                        if which[i] == 1:
                            close_fd(self._out_fd)
                            self._out_fd = -1
                        else:
                            close_fd(self._err_fd)
                            self._err_fd = -1
                        _ = fds.pop(i)
                        _ = which.pop(i)
                    elif which[i] == 1:
                        out_cap.add(buf, n)
                    else:
                        err_cap.add(buf, n)
                i -= 1

        if not timed_out and not self._reaped:
            if self._deadline_ns < 0:
                var r = waitpid(self.pid, 0)
                self._reap(r[1])
            else:
                var pause = 1
                while True:
                    var r = waitpid(self.pid, WNOHANG)
                    if r[0] == self.pid:
                        self._reap(r[1])
                        break
                    if self._remaining_ms() == 0:
                        self._terminate()
                        break
                    sleep_ms(min(pause, max(self._remaining_ms(), 1)))
                    pause = min(pause * 2, 50)

        close_fd(self._out_fd)
        close_fd(self._err_fd)
        self._out_fd = -1
        self._err_fd = -1
        var out_trunc = out_cap.truncated()
        var err_trunc = err_cap.truncated()
        return Output(
            self._status,
            out_cap.take(),
            err_cap.take(),
            out_trunc,
            err_trunc,
            monotonic_ns() - self._started_ns,
        )


# ── Command ─────────────────────────────────────────────────────────────────


def _env_key(entry: String) -> String:
    var at = entry.find("=")
    if at < 0:
        return entry
    return String(entry[byte=0:at])


struct Command(Movable):
    """A program to run, and how to run it.

    The setters take and return the command, so they chain:

        var out = Command("git").arg("status").cwd(repo).run()

    Arguments go straight to the program: nothing is parsed by a shell.
    """

    var _program: String
    var _args: List[String]
    var _env_set: List[String]
    var _env_remove: List[String]
    var _env_clear: Bool
    var _cwd: String
    var _stdin: Stdio
    var _stdout: Stdio
    var _stderr: Stdio
    var _timeout_ns: Int
    var _grace_ms: Int
    var _capture_limit: Int
    var _limits: Limits

    def __init__(out self, program: String):
        self._program = program
        self._args = List[String]()
        self._env_set = List[String]()
        self._env_remove = List[String]()
        self._env_clear = False
        self._cwd = String()
        self._stdin = Stdio.null()
        self._stdout = Stdio.capture()
        self._stderr = Stdio.capture()
        self._timeout_ns = -1
        self._grace_ms = 5000
        self._capture_limit = 64 << 20
        self._limits = Limits()

    def arg(var self, a: String) -> Self:
        self._args.append(a)
        return self^

    def args(var self, a: List[String]) -> Self:
        for s in a:
            self._args.append(s)
        return self^

    def env(var self, key: String, value: String) -> Self:
        """Sets `key` in the child's environment."""
        self._env_set.append(String(key, "=", value))
        return self^

    def env_remove(var self, key: String) -> Self:
        self._env_remove.append(key)
        return self^

    def env_clear(var self) -> Self:
        """Starts the child's environment empty instead of from the parent's."""
        self._env_clear = True
        return self^

    def cwd(var self, path: String) -> Self:
        self._cwd = path
        return self^

    def stdin(var self, s: Stdio) -> Self:
        self._stdin = s.copy()
        return self^

    def stdout(var self, s: Stdio) -> Self:
        self._stdout = s.copy()
        return self^

    def stderr(var self, s: Stdio) -> Self:
        self._stderr = s.copy()
        return self^

    def timeout_ms(var self, ms: Int) -> Self:
        """Stops the child's process group if it runs longer than `ms`."""
        self._timeout_ns = ms * 1_000_000
        return self^

    def timeout_seconds(var self, s: Int) -> Self:
        self._timeout_ns = s * 1_000_000_000
        return self^

    def kill_grace_ms(var self, ms: Int) -> Self:
        """Time between SIGTERM and SIGKILL at a timeout (default 5000)."""
        self._grace_ms = ms
        return self^

    def capture_limit(var self, n_bytes: Int) -> Self:
        """Bytes kept per captured stream: the first and last half (64 MiB)."""
        self._capture_limit = n_bytes
        return self^

    def limits(var self, lim: Limits) -> Self:
        self._limits = lim.copy()
        return self^

    def _environment(self) -> List[String]:
        var base = List[String]()
        if not self._env_clear:
            base = current_environment()
        var out = List[String]()
        for e in base:
            var k = _env_key(e)
            var drop = False
            for r in self._env_remove:
                if r == k:
                    drop = True
            for s in self._env_set:
                if _env_key(s) == k:
                    drop = True
            if not drop:
                out.append(e)
        for s in self._env_set:
            out.append(s)
        return out^

    def _resolve(self, env: List[String]) raises -> String:
        if self._program.find("/") >= 0:
            return self._program
        var path = String("/usr/bin:/bin")
        for e in env:
            if e.startswith("PATH="):
                path = String(e[byte=5:])
        for d in path.split(":"):
            var dir = String(d) if d.byte_length() > 0 else String(".")
            var cand = String(dir, "/", self._program)
            if is_executable(cand):
                return cand
        raise Error(
            "exec ",
            self._program,
            ": not found in PATH (",
            path,
            ")",
        )

    def spawn(self) raises -> Child:
        """Starts the child and returns at once."""
        var env = self._environment()
        var path = self._resolve(env)

        var argv = _CStrings()
        argv.add(self._program)
        for a in self._args:
            argv.add(a)
        var envp = _CStrings()
        for e in env:
            envp.add(e)
        var misc = _CStrings()  # 0: path, 1: cwd
        misc.add(path)
        misc.add(self._cwd)
        var argv_p = argv.finish()
        var envp_p = envp.finish()
        _ = misc.finish()

        var rl = List[UInt8]()
        var n_rl = 0
        var lim_vals: List[Int] = [
            self._limits.cpu_seconds,
            self._limits.file_size_bytes,
            self._limits.open_files,
        ]
        var lim_res: List[c_int] = [RLIMIT_CPU, RLIMIT_FSIZE, RLIMIT_NOFILE]
        for i in range(3):
            if lim_vals[i] >= 0:
                for _ in range(16):
                    rl.append(0)
                write_u64(addr_of(rl) + n_rl * 16, UInt64(Int(lim_res[i])))
                write_u64(addr_of(rl) + n_rl * 16 + 8, UInt64(lim_vals[i]))
                n_rl += 1
        if len(rl) == 0:
            rl.append(0)
        var zeros = List[UInt8](length=SIGACTION_BYTES, fill=0)

        # `child_side` holds the descriptors the child gets, closed in the
        # parent after fork; `parent_side` the ones the parent keeps.
        var child_side = _Fds()
        var parent_side = _Fds()
        var fd_in = c_int(-1)
        var fd_out = c_int(-1)
        var fd_err = c_int(-1)
        var rd_out = c_int(-1)
        var rd_err = c_int(-1)

        if self._stdin.kind == Stdio.NULL:
            fd_in = child_side.add(open_null())
        elif self._stdin.kind == Stdio.FILE:
            fd_in = child_side.add(open_read(self._stdin.path))
        elif self._stdin.kind == Stdio.CAPTURE:
            raise Error("stdin can't be captured: use null, inherit or file")

        if self._stdout.kind == Stdio.NULL:
            fd_out = child_side.add(open_null())
        elif self._stdout.kind == Stdio.FILE:
            fd_out = child_side.add(open_append(self._stdout.path))
        elif self._stdout.kind == Stdio.CAPTURE:
            var p = pipe_cloexec()
            rd_out = parent_side.add(p[0])
            fd_out = child_side.add(p[1])

        if self._stderr.kind == Stdio.NULL:
            fd_err = child_side.add(open_null())
        elif self._stderr.kind == Stdio.FILE:
            fd_err = child_side.add(open_append(self._stderr.path))
        elif self._stderr.kind == Stdio.CAPTURE:
            var p = pipe_cloexec()
            rd_err = parent_side.add(p[0])
            fd_err = child_side.add(p[1])

        var ep = pipe_cloexec()
        var err_r = parent_side.add(ep[0])
        var err_w = child_side.add(ep[1])

        var spawn = _SpawnAttrs()
        var plan = _ChildPlan(
            misc.at(0),
            argv_p,
            envp_p,
            misc.at(1) if self._cwd.byte_length() > 0 else 0,
            fd_in,
            fd_out,
            fd_err,
            err_w,
            addr_of(rl),
            n_rl,
            addr_of(zeros),
            spawn.attr_addr(),
            spawn.actions_addr(),
        )
        var started = monotonic_ns()
        var pid = fork()
        if pid == 0:
            _child_main(plan)
            external_call["_exit", NoneType](c_int(127))
        # Both sides set the group, so a kill right after spawn can't race
        # the child's own setpgid.
        setpgid(pid, pid)
        child_side.close_all()
        # The child has its own copies now. Until here every buffer whose
        # address is in `plan` had to stay alive.
        _ = argv^
        _ = envp^
        _ = misc^
        _ = rl^
        _ = zeros^
        _ = spawn^

        # The error pipe: EOF means exec succeeded; 8 bytes say what failed.
        var msg = List[UInt8](length=8, fill=0)
        var got = 0
        while got < 8:
            var part = List[UInt8](length=8 - got, fill=0)
            var n = read_some(err_r, part)
            if n == 0:
                break
            for j in range(n):
                msg[got + j] = part[j]
            got += n
        if got > 0:
            _ = waitpid(pid, 0)
            var at = addr_of(msg)
            var step = Int(read_i32(at))
            var code = c_int(read_i32(at + 4))
            _ = msg^
            if step == _STEP_EXEC:
                raise Error("exec ", path, ": ", describe_errno(code))
            if step == _STEP_CHDIR:
                raise Error("chdir ", self._cwd, ": ", describe_errno(code))
            raise Error(_step_name(step), ": ", describe_errno(code))

        var child = Child(
            pid,
            parent_side.take(rd_out),
            parent_side.take(rd_err),
            self._timeout_ns,
            self._grace_ms,
            self._capture_limit,
            started,
        )
        _ = parent_side^  # closes the error pipe's read end
        return child^

    def run(self) raises -> Output:
        """Starts the child, waits for it, and returns its output and status."""
        var child = self.spawn()
        return child.wait()

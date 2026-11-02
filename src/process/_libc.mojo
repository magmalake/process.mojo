"""The libc calls process makes, and the constants that differ by platform.

Pointers cross `external_call` as `Int` addresses. Mojo destroys a value
right after its last use, and taking its address counts as that use, so every
buffer whose address is passed is kept alive explicitly with `_ = buf^` after
the last call that reads or writes through the address.

Variadic C functions are called with `num_fixed_args`, so their variadic
arguments go where Apple's arm64 ABI expects them, on the stack. Close-on-exec
is set with `pipe2`/`O_CLOEXEC` on Linux and `ioctl(fd, FIOCLEX)` on macOS.
"""

from std.ffi import (
    c_int,
    c_short,
    c_size_t,
    c_ssize_t,
    c_uint,
    external_call,
    get_errno,
)
from std.memory import Pointer, stack_allocation
from std.sys.info import CompilationTarget, platform_map

comptime _pm = platform_map[T=Int, ...]

comptime IS_LINUX = CompilationTarget.is_linux()

comptime EPERM: c_int = 1
comptime ENOENT: c_int = 2
comptime ESRCH: c_int = 3
comptime EINTR: c_int = 4
comptime EACCES: c_int = 13
comptime ECHILD: c_int = 10
comptime EINVAL: c_int = 22
comptime ENOSYS: c_int = c_int(_pm["ENOSYS", linux=38, macos=78]())

comptime SIGKILL: c_int = 9
comptime SIGTERM: c_int = 15
comptime WNOHANG: c_int = 1
comptime X_OK: c_int = 1

comptime O_RDONLY: c_int = 0
comptime O_WRONLY: c_int = 1
comptime O_RDWR: c_int = 2
comptime O_APPEND: c_int = c_int(_pm["O_APPEND", linux=0x400, macos=0x8]())
comptime O_CREAT: c_int = c_int(_pm["O_CREAT", linux=0x40, macos=0x200]())
comptime O_CLOEXEC: c_int = c_int(
    _pm["O_CLOEXEC", linux=0x80000, macos=0x1000000]()
)

comptime RLIMIT_CPU: c_int = 0
comptime RLIMIT_FSIZE: c_int = 1
comptime RLIMIT_NOFILE: c_int = c_int(_pm["RLIMIT_NOFILE", linux=7, macos=8]())

comptime CLOCK_MONOTONIC: c_int = c_int(
    _pm["CLOCK_MONOTONIC", linux=1, macos=6]()
)
comptime SIG_SETMASK: c_int = c_int(_pm["SIG_SETMASK", linux=2, macos=3]())
# Highest signal number + 1: glibc's _NSIG is 65, Darwin's NSIG is 32.
comptime NSIG = _pm["NSIG", linux=65, macos=32]()
# `sigset_t` is 128 bytes in glibc and 4 on Darwin; a zeroed buffer of the
# larger size is an empty set on both. `struct sigaction` all zeroes is
# SIG_DFL with no flags on both.
comptime SIGSET_BYTES = 128
comptime SIGACTION_BYTES = 256

comptime FIOCLEX: Int = 0x20006601  # macOS: _IO('f', 1)

# macOS posix_spawn flags (spawn.h).
comptime POSIX_SPAWN_SETSIGDEF: c_short = 0x04
comptime POSIX_SPAWN_SETSIGMASK: c_short = 0x08
comptime POSIX_SPAWN_SETEXEC: c_short = 0x40
comptime POSIX_SPAWN_CLOEXEC_DEFAULT: c_short = 0x4000

# Linux close_range(2): the same number on x86_64 and aarch64.
comptime SYS_CLOSE_RANGE = 436

comptime POLLIN: Int16 = 0x1
comptime POLLERR: Int16 = 0x8
comptime POLLHUP: Int16 = 0x10
comptime POLLFD_SIZE = 8


comptime CPtr = Pointer[NoneType, MutUntrackedOrigin]
"""How every address crosses `external_call`.

Within one program, every `external_call` to a C symbol must use the same
signature, the stdlib's and other libraries' included: dista declares `poll`
and `waitpid` with pointer arguments, and an `Int` here would refuse to link
with it. So addresses are passed as pointers, never as `Int`.
"""


def cp(addr: Int) -> CPtr:
    """The pointer for address `addr` (0 is NULL)."""
    return CPtr(unsafe_from_address=addr)


def errno() -> c_int:
    return get_errno().value


def cstring_at(addr: Int) -> String:
    """Copies the NUL-terminated C string at `addr`."""
    if addr == 0:
        return String()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var n = 0
    while p.unsafe_offset(n)[] != 0:
        n += 1
    return String(
        unsafe_from_utf8=Span[UInt8, MutUntrackedOrigin](unsafe_ptr=p, length=n)
    )


def strerror(code: c_int) -> String:
    return cstring_at(Int(external_call["strerror", CPtr](code)))


def describe_errno(code: c_int) -> String:
    return String(strerror(code), " (errno ", code, ")")


def read_i32(addr: Int) -> Int32:
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=addr
    ).unsafe_bitcast[Int32]()[]


def write_i32(addr: Int, v: Int32):
    Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr).unsafe_bitcast[
        Int32
    ]().unsafe_write(v)


def read_u64(addr: Int) -> UInt64:
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=addr
    ).unsafe_bitcast[UInt64]()[]


def write_u64(addr: Int, v: UInt64):
    Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr).unsafe_bitcast[
        UInt64
    ]().unsafe_write(v)


def addr_of(mut buf: List[UInt8]) -> Int:
    return Int(buf.unsafe_ptr())


def cbytes(s: String) -> List[UInt8]:
    """`s` as a NUL-terminated byte buffer; pass `addr_of` it to C."""
    var sp = s.as_bytes()
    var out = List[UInt8](capacity=len(sp) + 1)
    for i in range(len(sp)):
        out.append(sp[i])
    out.append(0)
    return out^


def set_cloexec(fd: c_int) raises:
    comptime if IS_LINUX:
        # Linux fds made here come from pipe2/open with O_CLOEXEC already.
        return
    else:
        if external_call["ioctl", c_int](fd, FIOCLEX) != 0:
            raise Error("ioctl(FIOCLEX): ", describe_errno(errno()))


def pipe_cloexec() raises -> Tuple[c_int, c_int]:
    """A pipe whose two ends are close-on-exec. Returns (read end, write end).
    """
    var fds = List[UInt8](length=8, fill=0)
    var a = addr_of(fds)
    var rc: c_int
    comptime if IS_LINUX:
        rc = external_call["pipe2", c_int](cp(a), O_CLOEXEC)
    else:
        rc = external_call["pipe", c_int](cp(a))
    if rc != 0:
        raise Error("pipe: ", describe_errno(errno()))
    var r = c_int(read_i32(a))
    var w = c_int(read_i32(a + 4))
    _ = fds^  # keep the buffer alive past the reads through `a`
    comptime if not IS_LINUX:
        set_cloexec(r)
        set_cloexec(w)
    return (r, w)


def close_fd(fd: c_int):
    if fd >= 0:
        _ = external_call["close", c_int](fd)


def _open(path: String, flags: c_int, mode: Int = 0) raises -> c_int:
    """`open(2)`, declared exactly as memory-region declares it: variadic
    after two fixed arguments. Two declarations of one symbol in a program
    must agree, and `num_fixed_args` is also what makes the mode reach
    Apple's arm64 `open`, which reads variadic arguments from the stack."""
    var p = cbytes(path)
    var fd = external_call["open", Int32, num_fixed_args=2](
        p.unsafe_ptr(), Int32(flags), Int32(mode)
    )
    _ = p^
    if fd < 0:
        raise Error("open ", path, ": ", describe_errno(errno()))
    set_cloexec(c_int(fd))
    return c_int(fd)


def open_read(path: String) raises -> c_int:
    return _open(path, O_RDONLY | O_CLOEXEC)


def open_null() raises -> c_int:
    return _open("/dev/null", O_RDWR | O_CLOEXEC)


def open_append(path: String) raises -> c_int:
    """Opens `path` for appending, creating it (mode 0644) if it's missing."""
    return _open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)


def read_some(fd: c_int, mut buf: List[UInt8]) raises -> Int:
    """Reads into `buf` (its whole length). Returns the bytes read, 0 at EOF."""
    while True:
        var n = external_call["read", c_ssize_t](
            fd, cp(addr_of(buf)), c_size_t(len(buf))
        )
        if n >= 0:
            return Int(n)
        if errno() != EINTR:
            raise Error("read: ", describe_errno(errno()))


def is_executable(path: String) -> Bool:
    var p = cbytes(path)
    var rc = external_call["access", c_int](cp(addr_of(p)), X_OK)
    _ = p^
    return rc == 0


def monotonic_ns() -> Int:
    # A typed pointer, not an address: the stdlib declares clock_gettime
    # too, and on Linux two declarations must agree.
    var ts = Array[Int64, 2](fill=0)
    _ = external_call["clock_gettime", c_int](CLOCK_MONOTONIC, ts.unsafe_ptr())
    return Int(ts[0]) * 1_000_000_000 + Int(ts[1])


def poll_fds(fds: List[c_int], timeout_ms: Int) raises -> List[Int16]:
    """Waits for input on any of `fds` or for `timeout_ms` (-1: forever).

    Returns each descriptor's `revents`; all zero on timeout.
    """
    var n = len(fds)
    var buf = List[UInt8](length=max(n, 1) * POLLFD_SIZE, fill=0)
    var base = addr_of(buf)
    for i in range(n):
        write_i32(base + i * POLLFD_SIZE, Int32(fds[i]))
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=base + i * POLLFD_SIZE + 4
        ).unsafe_bitcast[Int16]().unsafe_write(POLLIN)
    while True:
        var r = external_call["poll", c_int](
            cp(base), c_uint(n), c_int(timeout_ms)
        )
        if r >= 0:
            break
        if errno() != EINTR:
            raise Error("poll: ", describe_errno(errno()))
    var out = List[Int16](length=n, fill=0)
    for i in range(n):
        out[i] = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=base + i * POLLFD_SIZE + 6
        ).unsafe_bitcast[Int16]()[]
    _ = buf^
    return out^


def sleep_ms(ms: Int):
    _ = external_call["poll", c_int](cp(0), c_uint(0), c_int(ms))


def waitpid(pid: Int, flags: c_int) raises -> Tuple[Int, Int]:
    """`waitpid(2)`, retried on EINTR. Returns (pid or 0, raw status)."""
    var st = List[UInt8](length=8, fill=0)
    var a = addr_of(st)
    while True:
        var r = external_call["waitpid", c_int](c_int(pid), cp(a), flags)
        if r >= 0:
            var status = Int(read_i32(a))
            _ = st^
            return (Int(r), status)
        if errno() != EINTR:
            raise Error("waitpid: ", describe_errno(errno()))


def kill_group(pgid: Int, sig: c_int):
    _ = external_call["kill", c_int](c_int(-pgid), sig)


def setpgid(pid: Int, pgid: Int):
    _ = external_call["setpgid", c_int](c_int(pid), c_int(pgid))


def fork() raises -> Int:
    var pid = external_call["fork", c_int]()
    if pid < 0:
        raise Error("fork: ", describe_errno(errno()))
    return Int(pid)


def environ_ptr() -> Int:
    """The address of the process's `environ` array (`char **`)."""
    comptime if IS_LINUX:
        var name = cbytes(String("environ"))
        var sym = Int(external_call["dlsym", CPtr](cp(0), cp(addr_of(name))))
        _ = name^
        if sym == 0:
            return 0
        return Int(read_u64(sym))
    else:
        var p = Int(external_call["_NSGetEnviron", CPtr]())
        if p == 0:
            return 0
        return Int(read_u64(p))


def current_environment() -> List[String]:
    """The parent's environment, as `KEY=value` strings."""
    var out = List[String]()
    var env = environ_ptr()
    if env == 0:
        return out^
    var i = 0
    while True:
        var s = Int(read_u64(env + i * 8))
        if s == 0:
            break
        out.append(cstring_at(s))
        i += 1
    return out^


def realpath(path: String) raises -> String:
    var p = cbytes(path)
    var buf = List[UInt8](length=4096, fill=0)
    var r = Int(
        external_call["realpath", CPtr](cp(addr_of(p)), cp(addr_of(buf)))
    )
    _ = p^
    if r == 0:
        raise Error("realpath ", path, ": ", describe_errno(errno()))
    var out = cstring_at(addr_of(buf))
    _ = buf^
    return out^

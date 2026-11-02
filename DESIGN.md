# process: design

November 2, 2026 · targets stable Mojo 1.2.0 and current nightly, on osx-arm64, linux-64 and linux-aarch64

process runs programs from Mojo. It starts a child with arguments, an environment and a working directory, captures what it writes, stops it when it runs too long, limits what it can use and, when asked, sandboxes it: no network, no writes outside the directories you name, no reads outside the system and the directories you name.

Everything marked *measured* was run on this machine (macOS 26.6, and Linux 6.8 aarch64 under colima). Every other claim is checked in the PR that first needs it, and this file is corrected when one turns out wrong.

## Why

- **Mojo has no usable way to run a program.** `std.subprocess.run(cmd) -> String` is `popen` through a shell. It returns stdout and nothing else: no exit status, no stderr, no environment, no working directory, no timeout. A build that fails looks the same as one that printed nothing.
- **magmalake already writes this code privately, twice.** dista's `socket.mojo` has `fork`, `waitpid` and `_exit`. flare has `utils/posix_proc.mojo`. Neither is meant for running someone else's program.
- **shelfwatch needs it, sandboxed.** The nightly pipeline that builds and tests every tin on mojoshelf runs a dista task per tin, and the task runs `pixi install`, `mojo build` and `pixi run test` on a repository nobody here wrote. That code must not read the worker's credentials, write outside its scratch directory, reach the network after its install step, or see dista's shared-memory store.
- **It keeps dista and orca free of it.** dista has no dependencies and orca adds no FFI. The platform sandbox code lives here instead, and they depend on it only where they run external programs.

## What it is not

- **Not a container runtime.** No images, no namespaces of its own on macOS, no cgroups in v0. A sandbox here is a policy the kernel enforces on one process tree.
- **Not a shell.** Arguments are a list and go straight to `execve`. There is no quoting, globbing or `sh -c`, unless you run `sh -c` yourself.
- **Not hard isolation against a kernel exploit.** Seatbelt and Landlock with seccomp are the same layer Codex CLI, Claude Code and Chrome's renderers use. Against a kernel bug the answer is a VM or a separate machine, which is Kubernetes' job (orca's phase 5), not this tin's.

## API

```mojo
from process import Command, Sandbox, Stdio, Limits

def build_tin(scratch: String, cache: String, toolchain: String) raises -> Int:
    var sb = Sandbox()                    # deny by default: no network, no writes
    sb.allow_read(cache)                  # shared pixi/rattler cache, read-only
    sb.allow_read(toolchain)
    sb.allow_write(scratch)               # write implies read
    sb.allow_toolchain()                  # the platform's C toolchain and linker

    var lim = Limits()
    lim.cpu_seconds = 1800
    lim.file_size_bytes = 4 << 30

    var cmd = Command("pixi")
    cmd.args(["run", "test"])
    cmd.cwd(scratch)
    cmd.env_clear()
    cmd.env("HOME", scratch)
    cmd.env("PATH", "/usr/bin:/bin")
    cmd.timeout_seconds(900)
    cmd.limits(lim)
    cmd.sandbox(sb)                       # leave out for no sandbox
    var out = cmd.run()                   # waits; stdout and stderr captured
    print(out.status, out.wall_ns)        # exited 0 | killed by signal 9 | timed out
    return out.status.code()
```

| Type | What it is |
|---|---|
| `Command` | A program, its arguments, environment, working directory, stdio, timeout, limits and sandbox. `run()` waits and returns an `Output`; `spawn()` returns a `Child`. |
| `Child` | A running process group: `pid`, `wait()`, `try_wait()`, `kill()`. |
| `Output` | `status`, `stdout` and `stderr` as `List[UInt8]` (with `stdout_text()`), `wall_ns`, and `truncated` when a capture cap was hit. |
| `ExitStatus` | Exited with a code, killed by a signal, or timed out. `success()` is exited 0. |
| `Stdio` | `inherit`, `null`, `capture` (the default for stdout and stderr; `null` is the default for stdin), or `file(path)` (append, created 0644). orca's per-attempt logs use `file`. |
| `Limits` | `cpu_seconds`, `open_files`, `file_size_bytes`, as `setrlimit` in the child. No memory limit yet, see below. |
| `Sandbox` | Paths to read, paths to write, `allow_network()`, `allow_toolchain()`. `Sandbox.available()` says whether this host can enforce one. |

Everything raises on a setup error (missing program, unreadable working directory, sandbox unavailable) with the step and the errno in the message, as in `exec /usr/bin/pixy: No such file or directory (errno 2)`.

### Two modes, chosen by the caller

The two modes are `none` (no `sandbox()` call) and `sandbox`. There's no global switch and no environment variable that turns a sandbox off. A caller that wants "trusted tins run plain, others sandboxed" decides per command. That keeps the decision in the code that knows where the program came from.

A `Sandbox` that cannot be enforced raises. It never quietly runs the program unsandboxed. Examples are Linux without Landlock, or a seccomp filter the kernel refuses.

## How a child starts

Every child starts through one path on both platforms: `fork`, then a short list of system calls in the child, then `execve`.

**Before `fork`, the parent prepares everything.** This includes the resolved program path, `argv` and `envp` as C arrays, the working directory, the rlimits, the pipes, and, on Linux, the Landlock ruleset descriptor and the seccomp BPF program. On macOS it also prepares the Seatbelt profile text. The child allocates nothing and calls no Mojo code that might. Only async-signal-safe calls run between `fork` and `execve`, so it's safe to fork from a multithreaded parent such as a dista worker.

**The child, in order:**

1. `setpgid(0, 0)`, so the child leads a new process group and a timeout can kill its whole tree.
2. `dup2` the prepared stdin, stdout and stderr onto 0, 1 and 2.
3. `chdir` and `setrlimit`.
4. *Linux:* unblock every signal and reset every disposition to default (`SIG_IGN` survives exec), then close every descriptor from 3 up with `close_range`, except the error pipe.
5. *Linux, sandboxed:* `prctl(PR_SET_NO_NEW_PRIVS)`, `landlock_restrict_self(ruleset)`, then the seccomp filter.
6. *Linux:* `execve`. *macOS:* `posix_spawn` with `POSIX_SPAWN_SETEXEC`, which execs in place. Its attributes reset the signal mask and dispositions, and `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every descriptor except 0, 1 and 2, which are named in its file actions. macOS has no `close_range`, and this does the same job atomically. *macOS, sandboxed:* the program it execs is `/usr/bin/sandbox-exec -p <profile> -- <program> <args>`.

A child never inherits a dista socket or a store mapping.

*Measured* on macOS 26: posix_spawn's own `dup2` file action fails with `EBADF` under `SETEXEC` when the source descriptor is close-on-exec, because the kernel closes those before it runs the actions. A ten-line C program shows the same thing. Every descriptor process makes is close-on-exec, so the child does its own `dup2` in step 2 on both platforms, and the file actions only mark 0, 1 and 2 as inherited.

`posix_spawn` isn't on POSIX's list of async-signal-safe functions. On macOS with `SETEXEC` it reads attributes prepared before `fork` and makes the `posix_spawn` system call, and it's the one place process relies on that implementation detail. The multithreaded-parent test in phase 4 is what checks it.

**Errors come back on a pipe.** Before `fork` the parent opens a close-on-exec pipe. If any step fails, the child writes the step number and errno to it and `_exit(127)`s. When `execve` succeeds the pipe closes, so the parent reads either end-of-file, meaning the program is running, or eight bytes saying what failed and why. "exec failed" is never confused with "the program exited 127". Rust's standard library uses the same trick.

**The program path is resolved in the parent.** It's looked up in the child's `PATH` (the one given to the command, not the parent's), before `fork`, because `execvp` may allocate. A name with a `/` is used as given.

### Why not `posix_spawn` alone

Plain `posix_spawn` with no `fork` is faster on macOS, and it's the safe default where it fits. It can't set rlimits, it can't apply Landlock or seccomp, and on macOS its `dup2` can't take close-on-exec sources (above). So every path would need a `fork` anyway. One code path that's tested everywhere beats two paths where one runs only when sandboxed. *Measured:* 200 sequential `echo`s take about 260 ms on macOS, 1.3 ms each, which is negligible next to a build. If profiling ever shows spawn cost matters for the `none` mode, a fork-free path can take it over without changing the API.

### Sharing libc with other libraries

*Measured* when the dista example first linked process and dista into one binary: within a program, every `external_call` to a C symbol must use the same signature, including the stdlib's and other libraries'. Otherwise the build fails with "existing function with conflicting signature". dista declares `poll` and `waitpid` with pointer arguments, the stdlib declares `clock_gettime`, and memory-region declares `open` as variadic after two fixed arguments. So process passes every address as a pointer (`CPtr`), never as an `Int`, and declares `open` exactly as memory-region does. `num_fixed_args` is also what makes variadic calls correct on Apple arm64, which reads variadic arguments from the stack. magmalake would benefit from one shared libc declaration module. Until one exists, the rule is: pointers as pointers, and the arity the C prototype has.

## Waiting, capturing, timing out

`run()` reads stdout and stderr from their pipes with `poll`, so neither pipe fills up and blocks the child. It stops at the deadline if there is one. Each capture keeps at most `capture_limit` bytes (default 64 MiB): the first half and the last half, with `truncated` set. A build log that explodes stays bounded, and both its beginning and its error at the end survive.

At the deadline the parent sends `SIGTERM` to the process group, waits a grace period (default 5 s), then sends `SIGKILL` to the group. The status is `timed out` no matter how the child died. It then reaps the child with `waitpid`.

A child that calls `setsid` leaves the group and survives the kill. v0 accepts that. The fix is a cgroup on Linux and nothing short of a VM on macOS, and builds and test runners don't call `setsid`.

## The sandbox on macOS: Seatbelt

`sandbox-exec -p` with a profile generated from the `Sandbox`. `sandbox-exec` is marked deprecated, but it ships with macOS 26, and Codex CLI, Claude Code, Bazel and Chrome depend on Seatbelt. If Apple removes the binary, the same profile goes through `sandbox_init` in the child.

```scheme
(version 1)
(deny default)
(allow process-exec process-fork sysctl-read file-read-metadata)
(allow signal (target same-sandbox))
(allow file-read* (literal "/") (subpath "/usr") (subpath "/bin") (subpath "/System")
  (subpath "/Library/Apple") (subpath "/private/etc") (subpath "/private/var/db/timezone")
  (subpath "/private/var/select")
  (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/tty"))
(allow file-write* (literal "/dev/null"))
; per Sandbox: (allow file-read* (subpath "<read>"))
; per Sandbox: (allow file-read* file-write* (subpath "<write>"))
; allow_toolchain(): Xcode or the Command Line Tools, its license plist, (allow iokit-open)
; allow_network():   (allow network*) (allow mach-lookup) for DNS
```

*Measured* with this profile:

| Check | Result |
|---|---|
| `cat ~/.zshrc` | `Operation not permitted` |
| `touch ~/x` | `Operation not permitted` |
| `curl https://example.com` | can't resolve the host: no DNS without `mach-lookup` |
| `curl http://1.1.1.1` | can't connect |
| `sh -c 'echo hi > $WORK/f && cat $WORK/f'` | works |
| `mojo run h.mojo` | works with `iokit-open` allowed and `MODULAR_HOME`/`MODULAR_CACHE_DIR` set; aborts (signal 5) without `iokit-open`, which the runtime needs to probe the GPU |
| `mojo build h.mojo && ./h` | works once the Xcode directory and `/Library/Preferences/com.apple.dt.Xcode.plist` are readable; without them `xcrun` fails and the link step fails |
| Start cost | 6.2 ms against 1.2 ms for `/usr/bin/true` plain, so about 5 ms per sandboxed start |

Findings that shape the code:

- **`/` itself must be readable** (`literal`, not `subpath`). Without it dyld aborts every program, even `/usr/bin/true`, before `main`.
- **Paths must be canonical.** Seatbelt matches real paths: `/tmp` is `/private/tmp`, and here `~/dev` is a symlink to `/Volumes/ExtNVMe/dev`. `allow_read` and `allow_write` resolve with `realpath` when the sandbox is applied, and raise if a path doesn't exist.
- **No blanket `mach-lookup`.** Allowing every Mach service would leave DNS (mDNSResponder), the keychain (securityd) and the pasteboard reachable. The toolchain works without it. `allow_network()` turns it back on, since name resolution needs it.
- **`$TMPDIR` is not readable by default.** That's where dista's store lives on macOS (`/var/folders/...`). A sandboxed child that needs a temp directory gets one inside a write path, through the environment.
- **Paths are escaped** for the profile's string syntax (`\` and `"`), and are passed in the profile text, not as `-D` parameters, so a sandbox has no fixed set of parameter names.

## The sandbox on Linux: Landlock and seccomp

**Filesystem: Landlock.** The parent creates a ruleset that handles every filesystem access right the kernel's ABI knows. It adds read-and-execute rules for the system paths and the `allow_read` paths, and read-write rules for the `allow_write` paths. The child applies it with `landlock_restrict_self`. *Measured:* Landlock ABI 4 on the colima 6.8 kernel, inside Docker's default seccomp profile. GitHub's Ubuntu 24.04 runners have 6.8 or newer as well.

System read paths are `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/etc`, `/proc`, `/sys/devices/system/cpu`, and the files `/dev/null`, `/dev/zero`, `/dev/urandom`, `/dev/random` and `/dev/tty`, corrected in the Linux PR to what the Mojo runtime and pixi actually open. Two exclusions matter: `/dev/shm`, which is dista's object store, and `/tmp`.

**Network and the rest: seccomp.** A BPF filter, built in the parent per architecture (x86_64 and aarch64), returns `EPERM` for:

- `socket()` of any family. Without `allow_network()`, no new sockets at all, including `AF_UNIX`. Landlock doesn't govern `connect` to a named Unix socket, and that would reach `/var/run/docker.sock` if it exists. `socketpair` stays allowed, since tools use it for local plumbing.
- `io_uring_setup`, `io_uring_enter` and `io_uring_register`, whose operations would bypass the socket rule.
- `ptrace`, `process_vm_readv` and `process_vm_writev`.
- the x32 ABI on x86_64, and any architecture other than the one built for, so a filter written for one numbering can't be bypassed through another.

seccomp handles the network rather than Landlock's TCP rules because Landlock's network rights (ABI 4) cover TCP `bind` and `connect` only, not UDP. DNS would still get out.

**What Linux can't do below Landlock ABI 6.** Signals and abstract Unix sockets are scoped only from ABI 6 (kernel 6.12). Below that, a sandboxed child can signal other processes of the same user, the dista worker included. process applies those scopes when the kernel has them and reports the ABI in `Sandbox.describe()`. Below 6, run untrusted builds under their own user, which a Kubernetes pod does anyway.

**Secrets in `/proc`.** `/proc/<pid>/environ` of a same-user process is readable unless that process is non-dumpable. `process.harden_current_process()` calls `prctl(PR_SET_DUMPABLE, 0)`, which makes the caller's own `/proc` entries root-owned. A dista worker that runs untrusted builds should call it once at startup. The sandboxed child itself is unaffected.

## Memory limits

There aren't any in v0, deliberately. `RLIMIT_AS` would be the obvious limit, and it's wrong here. The Mojo runtime's allocator reserves large aligned regions of address space up front (threads.mojo's CI records TCMalloc asking for a 1 GiB-aligned mapping), so a virtual-size limit breaks Mojo programs long before they use the memory. macOS doesn't enforce `RLIMIT_AS` at all. The honest limit is a cgroup on Linux (`memory.max`), which needs a delegated cgroup, as a pod has. That's phase 4, Linux only. macOS gets a wall-clock timeout and a CPU limit, and that's all.

## Testing

- **Unit tests** (`pixi run test`), both toolchains × both platforms in CI: exit codes, signals, timeouts that kill a grandchild, capture of large and interleaved stdout and stderr, the capture cap, `Stdio.file`, environment clearing, `PATH` lookup, every setup error reported with the right step and errno, descriptors not leaking into the child, and ignored signals reset in the child. Spawning from a parent with several threads running is added in phase 4 with dista, which is where that parent comes from.
- **Sandbox tests** (`pixi run test-sandbox`): one set of escape attempts that must all fail on both platforms. Reading a file under `$HOME`, writing outside the write paths, following a symlink out of a write path, `connect` to an IP, a DNS lookup, connecting to a Unix socket the parent listens on, signalling the parent (Linux ABI ≥ 6, macOS), reading a `/dev/shm` file (Linux) or a `$TMPDIR` file (macOS). Plus the things that must work: `mojo build` and run of a small program, `pixi run` offline against a read-only cache.
- **Linux on a Mac** runs in Docker (`tests/linux.sh`), so the Landlock and seccomp path is exercised before a push. CI runs it natively on `ubuntu-latest` (x86_64) and on `ubuntu-24.04-arm` (aarch64), so both seccomp syscall tables are tested.

## Phases

Each phase ends at a gate: something that works, not a feature list.

| Phase | What | Gate |
|---|---|---|
| 1 | **Spawn.** `Command`, `Child`, `Output`, `Stdio`, `Limits`; fork/exec with the error pipe; `PATH` lookup; capture with `poll`; timeouts that kill the group. | The unit tests pass on osx-arm64 and linux-64, stable and nightly. A `sh -c 'sleep 100 & sleep 100'` with a 1 s timeout leaves no process behind. |
| 2 | **Seatbelt.** `Sandbox` on macOS, the generated profile, `allow_toolchain()`, canonical paths. | Every escape test fails and `mojo build` plus run of a program works, inside the sandbox, on macOS. |
| 3 | **Landlock and seccomp.** The ruleset, the BPF filter for both architectures, ABI detection and scopes, `harden_current_process()`. | The same tests on Linux, natively in CI and in Docker locally. A kernel without Landlock raises instead of running. |
| 4 | **In use.** shelfwatch's `build_tin` dista task over it (`examples/dista_build.mojo` is the sketch: one task per checkout, the log on the worker, a small result back); a cgroup memory limit on Linux; dista's and flare's private fork helpers replaced where it's a clean swap. | shelfwatch builds the magmalake tins nightly, each in its sandbox. |

## Open questions

- **`sandbox-exec` or `sandbox_init`.** Exec'ing the binary keeps the child free of a library call that compiles a profile, which allocates. `sandbox_init` would save the extra exec, about 5 ms. Stay with the binary until either the cost matters or the binary goes away.
- **A builder that chains.** `Command("pixi").arg("run").cwd(dir).run()` reads better than one statement per setting, but it needs `var self` methods returning `Self`. That's checked on both toolchains in phase 1 and adopted if it compiles cleanly on both.
- **Where the presets live.** `allow_toolchain()` knows about Xcode and the Mojo runtime's needs. A shelfwatch-specific preset (pixi cache, `MODULAR_CACHE_DIR`, a scratch `TMPDIR`) belongs in shelfwatch, not here.

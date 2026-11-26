# process.mojo

[![CI](https://github.com/magmalake/process.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/process.mojo/actions/workflows/ci.yml) [![Used by](https://mojourney.dev/badge/magmalake/process.mojo/used-by.svg)](https://mojourney.dev/repos/magmalake/process.mojo#used-by) [![Mojo version](https://mojourney.dev/badge/magmalake/process.mojo/mojo.svg)](https://mojourney.dev/repos/magmalake/process.mojo)

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

Run programs from Mojo: spawn them with arguments, an environment and a
working directory, capture stdout and stderr, time them out, and limit their
resources. Sandboxing (Seatbelt on macOS, Landlock and seccomp on Linux) is
next. No C shim and no dependencies: the Mojo standard library and libc.

It exists because `std.subprocess.run` is `popen` through a shell and returns
stdout only, with no exit status, stderr, environment, working directory or
timeout.

Works on the **Mojo 1.3 nightly 1.3.0.dev2026112605**, on **osx-arm64**,
**linux-64** and **linux-aarch64**.

```mojo
from process import Command, Limits, Stdio

def main() raises:
    var out = Command("git").args(["log", "-1", "--oneline"]).cwd("/src/repo").run()
    if out.status.success():
        print(out.stdout_text())
    else:
        print(out.status, out.stderr_text())   # "exited 128", "killed by signal 9", "timed out"

    var lim = Limits()
    lim.cpu_seconds = 600
    var build = (
        Command("pixi")
        .args(["run", "test"])
        .env_clear()
        .env("HOME", "/scratch")
        .env("PATH", "/usr/bin:/bin")
        .stdout(Stdio.file("/scratch/test.log"))
        .timeout_seconds(900)      # SIGTERM to the whole process group, then SIGKILL
        .limits(lim)
        .run()
    )
```

- **No shell.** Arguments go straight to `execve`; the program is looked up
  in the child's `PATH`.
- **Errors say what failed.** `exec /usr/bin/pixy: No such file or directory
  (errno 2)` is raised, not confused with a program that exited 127.
- **Timeouts kill the tree.** Every child leads its own process group, so a
  shell's background jobs go with it.
- **Bounded capture.** Each stream keeps at most 64 MiB by default — its first
  and last halves — with `stdout_truncated` set.
- **Nothing leaks in.** The child gets stdin, stdout and stderr and no other
  descriptor, and signal dispositions are back to default.

## Install

```toml
# pixi.toml
[dependencies]
process-mojo = { git = "https://github.com/magmalake/process.mojo" }
```

## Develop

```sh
pixi run test
pixi run lint
tests/linux.sh default test   # the same suite on Linux, in Docker
```

[DESIGN.md](DESIGN.md) is the plan: how a child starts, the sandbox on each
platform, and the phases.

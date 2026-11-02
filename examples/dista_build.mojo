"""Building and testing repositories across a dista cluster, one task per repo.

This is the shape of shelfwatch's nightly job: a dista task that runs a
program, here `pixi run <task>` in a checkout, with process doing the running.
The task is ordinary dista code; everything about the child (its environment,
log file, timeout, limits) is process's `Command`. The work it reports back is
a small struct, so nothing large crosses the cluster.

Local mode, every worker forked on this machine, over sibling checkouts:

    pixi run -e examples example-dista ../hashes.mojo ../zstd.mojo

On a cluster it's the same binary in each role (see dista's README); the
repositories must then exist at the same paths on every worker.

Phase 2 adds one line to `run_repo`: `.sandbox(sb)` with a `Sandbox` that
allows reads of the shared pixi cache and writes to the scratch directory
only, for repositories nobody here wrote. Until then, run trusted code only.
"""

from std.sys import argv

from dista import ObjectRef, Runtime, Task
from process import Command, Limits, Stdio


@fieldwise_init
struct RepoJob(Copyable, Movable):
    """What to run: a checkout, a pixi environment and task, a time budget."""

    var path: String
    var env: String
    var task: String
    var timeout_s: Int


@fieldwise_init
struct RepoResult(Copyable, Movable):
    """What came back: enough for a results table, plus where the log is."""

    var path: String
    var status: String
    var ok: Bool
    var wall_ms: Int
    var log: String
    var stderr_tail: String


def _tail(s: String, n_lines: Int) -> String:
    var lines = s.split("\n")
    var start = max(len(lines) - n_lines, 0)
    var out = String()
    for i in range(start, len(lines)):
        out += String(lines[i])
        if i + 1 < len(lines):
            out += "\n"
    return out^


def run_repo(job: RepoJob) raises -> RepoResult:
    """Runs on a worker. A setup error (no pixi, no checkout) raises and
    re-raises in the driver's `get`; a failing test is a result, not an error.
    """
    var manifest = String(job.path, "/pixi.toml")
    if not Command("test").args(["-f", manifest]).run().status.success():
        raise Error(job.path, " is not a pixi checkout (no pixi.toml)")
    var log = String(job.path, "/build/dista-", job.task, ".log")
    _ = Command("mkdir").args(["-p", String(job.path, "/build")]).run()

    var lim = Limits()
    lim.cpu_seconds = job.timeout_s * 4  # several cores, but not forever

    var out = (
        Command("pixi")
        .args(["run", "--manifest-path", manifest, "-e", job.env, job.task])
        .cwd(job.path)
        .stdout(Stdio.file(log))  # the whole log stays on the worker's disk
        .stderr(Stdio.capture())  # the end of stderr comes back in the result
        .capture_limit(64 << 10)
        .timeout_seconds(job.timeout_s)
        .limits(lim)
        .run()
    )
    return RepoResult(
        job.path,
        String(out.status),
        out.status.success(),
        out.wall_ns // 1_000_000,
        log,
        _tail(out.stderr_text(), 5),
    )


comptime RunRepo = Task[RepoJob, RepoResult, run_repo]


def main() raises:
    var args = argv()
    if len(args) < 2:
        print(
            "usage: dista_build <checkout>... (e.g. ../hashes.mojo"
            " ../zstd.mojo)"
        )
        return

    var rt = Runtime[RunRepo](workers=4)
    var refs = List[ObjectRef[RepoResult]]()
    for i in range(1, len(args)):
        refs.append(
            rt.remote[RunRepo](RepoJob(String(args[i]), "stable", "test", 1800))
        )

    var failed = 0
    for i in range(len(refs)):
        var res: RepoResult
        try:
            res = rt.get(refs[i])
        except e:  # the task raised on its worker
            print("ERR ", args[i + 1], "|", e)
            failed += 1
            continue
        var mark = "ok  " if res.ok else "FAIL"
        print(
            mark, res.path, "|", res.status, "|", res.wall_ms, "ms |", res.log
        )
        if not res.ok:
            failed += 1
            print("     ", res.stderr_tail)
    print(len(refs) - failed, "of", len(refs), "passed")

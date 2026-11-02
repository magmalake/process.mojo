"""Unit tests for process: spawn, capture, status, errors, timeouts, limits.

Everything runs real programs from the base system (`sh`, `cat`, `head`,
`env`, `pwd`), so the suite is the same on macOS and Linux.
"""

from std.ffi import c_int, external_call
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from process import Command, Limits, Stdio
from process._libc import (
    ESRCH,
    close_fd,
    errno,
    open_read,
    realpath,
)


def _tmpdir() raises -> String:
    var out = Command("mktemp").args(["-d"]).run()
    assert_true(out.status.success())
    return realpath(String(out.stdout_text().strip()))


def _sh(script: String) -> Command:
    return Command("sh").args(["-c", script])


def _raises_with(var cmd: Command, needle: String) raises:
    try:
        _ = cmd.run()
    except e:
        var msg = String(e)
        if msg.find(needle) < 0:
            raise Error(
                "expected an error containing '", needle, "', got: ", msg
            )
        return
    raise Error("expected an error containing '", needle, "', got none")


# ── output and status ───────────────────────────────────────────────────────


def test_stdout_captured() raises:
    var out = Command("echo").args(["hello", "world"]).run()
    assert_true(out.status.success())
    assert_equal(out.stdout_text(), "hello world\n")
    assert_equal(len(out.stderr), 0)
    assert_true(out.wall_ns > 0)


def test_exit_code_and_stderr() raises:
    var out = _sh("echo out; echo err >&2; exit 3").run()
    assert_true(out.status.exited())
    assert_equal(out.status.code(), 3)
    assert_false(out.status.success())
    assert_equal(out.stdout_text(), "out\n")
    assert_equal(out.stderr_text(), "err\n")


def test_killed_by_signal() raises:
    var out = _sh("kill -9 $$").run()
    assert_false(out.status.exited())
    assert_equal(out.status.signal(), 9)
    assert_equal(out.status.code(), -1)
    assert_equal(String(out.status), "killed by signal 9")


def test_large_output_on_both_streams() raises:
    # 2 MB on each pipe, written one after the other: a reader that drained
    # only one stream at a time would deadlock here.
    var out = _sh(
        "head -c 2000000 /dev/zero; head -c 2000000 /dev/zero >&2"
    ).run()
    assert_true(out.status.success())
    assert_equal(len(out.stdout), 2000000)
    assert_equal(len(out.stderr), 2000000)
    assert_false(out.stdout_truncated)


def test_capture_limit_keeps_head_and_tail() raises:
    var out = _sh("seq 1 100000").capture_limit(1000).run()
    assert_true(out.status.success())
    assert_true(out.stdout_truncated)
    assert_equal(len(out.stdout), 1000)
    var text = out.stdout_text()
    assert_true(text.startswith("1\n2\n3\n"))
    assert_true(text.endswith("99999\n100000\n"))


# ── errors ──────────────────────────────────────────────────────────────────


def test_missing_program_path() raises:
    _raises_with(Command("/nonexistent/prog"), "No such file or directory")


def test_missing_program_in_path() raises:
    _raises_with(Command("no-such-program-anywhere-xyz"), "not found in PATH")


def test_not_executable() raises:
    _raises_with(Command("/etc/hosts"), "exec /etc/hosts")


def test_missing_cwd() raises:
    _raises_with(
        Command("pwd").cwd("/nonexistent/dir"), "chdir /nonexistent/dir"
    )


def test_exit_127_is_not_an_exec_error() raises:
    var out = _sh("exit 127").run()
    assert_equal(out.status.code(), 127)


# ── environment and working directory ───────────────────────────────────────


def test_cwd() raises:
    var dir = _tmpdir()
    var out = Command("pwd").cwd(dir).run()
    assert_equal(out.stdout_text(), String(dir, "\n"))


def test_env_clear_and_set() raises:
    var out = (
        Command("/usr/bin/env")
        .env_clear()
        .env("A", "1")
        .env("B", "two words")
        .run()
    )
    assert_equal(out.stdout_text(), "A=1\nB=two words\n")


def test_env_inherited_and_overridden() raises:
    var out = _sh("echo $HOME:$PROCESS_TEST").env("PROCESS_TEST", "x").run()
    var text = out.stdout_text()
    assert_true(text.endswith(":x\n"))
    assert_true(text.byte_length() > 3)  # HOME came from the parent


def test_env_remove() raises:
    var out = _sh("echo [$HOME]").env_remove("HOME").run()
    assert_equal(out.stdout_text(), "[]\n")


def test_path_lookup_uses_child_path() raises:
    var dir = _tmpdir()
    _ = _sh(
        String(
            "printf '#!/bin/sh\\necho found-it\\n' > ",
            dir,
            "/my-tool && chmod +x ",
            dir,
            "/my-tool",
        )
    ).run()
    var out = (
        Command("my-tool").env("PATH", String(dir, ":/usr/bin:/bin")).run()
    )
    assert_equal(out.stdout_text(), "found-it\n")


# ── stdio ───────────────────────────────────────────────────────────────────


def test_stdin_null_is_empty() raises:
    var out = Command("cat").run()
    assert_true(out.status.success())
    assert_equal(len(out.stdout), 0)


def test_stdin_from_file() raises:
    var out = Command("cat").stdin(Stdio.file("/etc/hosts")).run()
    assert_true(out.status.success())
    assert_true(len(out.stdout) > 0)


def test_stdout_file_appends() raises:
    var dir = _tmpdir()
    var log = String(dir, "/run.log")
    _ = Command("echo").args(["one"]).stdout(Stdio.file(log)).run()
    var out = Command("echo").args(["two"]).stdout(Stdio.file(log)).run()
    assert_equal(len(out.stdout), 0)
    var cat = Command("cat").args([log]).run()
    assert_equal(cat.stdout_text(), "one\ntwo\n")


def test_stdout_null() raises:
    var out = Command("echo").args(["gone"]).stdout(Stdio.null()).run()
    assert_true(out.status.success())
    assert_equal(len(out.stdout), 0)


# ── isolation from the parent ───────────────────────────────────────────────


def test_parent_descriptors_do_not_leak() raises:
    var fd = open_read("/etc/hosts")
    # `: <&N` fails in the child unless descriptor N is open there.
    var out = _sh(String(": <&", fd)).run()
    close_fd(fd)
    assert_false(out.status.success())


def test_ignored_signals_are_reset() raises:
    # SIG_IGN survives exec; the child must get SIGTERM's default back.
    var prev = external_call["signal", Int](c_int(15), Int(1))
    var out = _sh("kill -TERM $$; sleep 5").timeout_seconds(4).run()
    _ = external_call["signal", Int](c_int(15), prev)
    assert_equal(out.status.signal(), 15)


def test_child_leads_its_own_group() raises:
    var out = _sh("ps -o pgid= -p $$; echo $$").run()
    var lines = out.stdout_text().strip().split("\n")
    assert_equal(String(lines[0].strip()), String(lines[1].strip()))


# ── timeouts ────────────────────────────────────────────────────────────────


def _alive(pid: Int) -> Bool:
    var rc = external_call["kill", c_int](c_int(pid), c_int(0))
    return rc == 0 or errno() != ESRCH


def test_timeout_kills_the_group() raises:
    var out = (
        _sh("sleep 100 & echo $!; sleep 100")
        .timeout_ms(300)
        .kill_grace_ms(200)
        .run()
    )
    assert_true(out.status.timed_out())
    assert_true(out.wall_ns < 3_000_000_000)
    var grandchild = Int(String(out.stdout_text().strip()))
    assert_false(_alive(grandchild))


def test_timeout_without_capture() raises:
    var out = (
        Command("sleep")
        .args(["100"])
        .stdout(Stdio.null())
        .stderr(Stdio.null())
        .timeout_ms(200)
        .run()
    )
    assert_true(out.status.timed_out())
    assert_true(out.wall_ns < 3_000_000_000)


def test_sigterm_ignored_falls_back_to_sigkill() raises:
    var out = (
        _sh("trap '' TERM; sleep 100").timeout_ms(200).kill_grace_ms(200).run()
    )
    assert_true(out.status.timed_out())
    assert_true(out.wall_ns < 3_000_000_000)


def test_fast_child_is_not_timed_out() raises:
    var out = Command("true").timeout_seconds(10).run()
    assert_true(out.status.success())


# ── limits ──────────────────────────────────────────────────────────────────


def test_open_files_limit() raises:
    var lim = Limits()
    lim.open_files = 64
    var out = _sh("ulimit -n").limits(lim).run()
    assert_equal(out.stdout_text(), "64\n")


def test_file_size_limit() raises:
    var dir = _tmpdir()
    var lim = Limits()
    lim.file_size_bytes = 4096
    var out = _sh("head -c 100000 /dev/zero > big").cwd(dir).limits(lim).run()
    assert_false(out.status.success())


def test_cpu_limit() raises:
    var lim = Limits()
    lim.cpu_seconds = 1
    var out = _sh("while :; do :; done").limits(lim).timeout_seconds(20).run()
    assert_false(out.status.timed_out())
    assert_true(
        out.status.signal() == 24 or out.status.signal() == 9
    )  # SIGXCPU


# ── spawn ───────────────────────────────────────────────────────────────────


def test_spawn_try_wait_kill() raises:
    var child = Command("sleep").args(["100"]).stdout(Stdio.null()).spawn()
    assert_true(child.pid > 0)
    assert_false(Bool(child.try_wait()))
    child.kill()
    var st = child.try_wait()
    assert_true(Bool(st))
    assert_equal(st.value().signal(), 9)


def test_many_children() raises:
    for i in range(200):
        var out = Command("echo").args([String(i)]).run()
        assert_equal(out.stdout_text(), String(i, "\n"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

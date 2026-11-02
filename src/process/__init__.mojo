"""Run programs from Mojo: spawn, capture, time out, limit and sandbox them.

    from process import Command

    var out = Command("git").args(["log", "-1"]).cwd(repo).run()
    if not out.status.success():
        print(out.stderr_text())
"""

from .command import Child, Command, ExitStatus, Limits, Output, Stdio

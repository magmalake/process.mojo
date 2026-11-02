# process.mojo

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

Run programs from Mojo: spawn them with arguments, environment and working
directory, capture stdout and stderr, time them out, limit their resources,
and optionally sandbox them — Seatbelt on macOS, Landlock and seccomp on
Linux. No C shim, no external binaries beyond what the OS ships.

Early days: [DESIGN.md](DESIGN.md) is the plan.

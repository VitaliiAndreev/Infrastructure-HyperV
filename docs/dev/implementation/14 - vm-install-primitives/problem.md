# VM install primitives: tarball extraction, symlinks, profile.d, directory removal, process control

## Index

- [Context](#context)
- [Problem](#problem)
- [Scope](#scope)
- [Out of scope](#out-of-scope)
- [Design decisions](#design-decisions)
- [Acceptance criteria](#acceptance-criteria)

## Context

`Infrastructure.HyperV` already owns the transport-layer primitives
that downstream repos use to act on a VM:
[Invoke-SshClientCommand](../../../../Infrastructure.HyperV/Public/Ssh/Invoke-SshClientCommand.ps1),
[Invoke-WithVmFileServer](../../../../Infrastructure.HyperV/Public/FileServer/Invoke-WithVmFileServer.ps1)
(host file server + `curl` from the VM, the streaming-tarball pattern),
[Copy-VmFiles](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFiles.ps1),
and
[Set-VmEnvironmentVariables](../../../../Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1).

Beyond transport, every downstream consumer that installs software on a
VM hand-rolls the same five guest-side operations as ad-hoc SSH
commands:

1. Stream a tarball from the host and extract it under sudo into a
   versioned target directory under `/opt`.
2. Create or remove a symlink under `/usr/local/bin` pointing at the
   freshly extracted binary, so non-login shells and systemd services
   see it on `PATH`.
3. Write a `/etc/profile.d/<name>.sh` snippet that exports variables
   (`JAVA_HOME`, `DOTNET_ROOT`, ...) into login shells.
4. Remove an install directory tree (the inverse of step 1) when the
   software is no longer wanted on the VM.
5. Find and stop processes holding files under an install directory
   so the directory can be removed safely.

The first three are paired (install path); the last two are the
uninstall path that the existing JDK feature has only partially
([Uninstall-Jdk](../../../../../Infrastructure-Vm-Provisioner/hyper-v/ubuntu/up/post/Uninstall-Jdk.ps1)
removes the dir but does not stop processes holding files in it). The next consumer
([Infrastructure-Vm-Provisioner/42 - dotnet sdk](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/42%20-%20dotnet%20sdk/problem.md))
is a declarative toolchain reconciler that builds install **and**
uninstall on top of all four. Without primitives in this repo, that
feature would either copy-paste the install snippets from
[Install-Jdk](../../../../../Infrastructure-Vm-Provisioner/hyper-v/ubuntu/up/post/Install-Jdk.ps1)
or grow them as ad-hoc SSH heredocs - both paths leak the bug classes
called out below.

## Problem

There is no transport-layer primitive for any of the four operations.
The current alternatives - copy-pasted SSH heredocs across consumer
repos - all share the same defects:

- **Duplicated logic in N places.** `Install-Jdk` already contains
  tarball extraction, symlink creation, and profile.d writing as raw
  shell strings. The dotnet SDK feature would copy them; a third
  toolchain would copy them again. Bug fixes (sudo handling, error
  reporting, idempotence) then have to land in every copy.
- **No idempotence.** A re-run of `tar -xzf` overwrites the directory
  half-extracted state if the first run died mid-way. A re-run of
  `ln -sf` is fine for the symlink itself but reveals nothing about
  whether the previous run finished. A re-run of `tee /etc/profile.d/...`
  is fine but cannot detect "content already matches, skip the write".
- **No removal path.** None of the existing primitives delete a
  symlink, remove a profile.d script, or kill processes holding files
  under a path. The uninstall side of the reconciler has no leverage.
- **Atomic-write defects.** Profile.d scripts written via `>` can be
  truncated by a crash mid-write. The existing
  [Set-VmEnvironmentVariables](../../../../Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1)
  already solved this for `/etc/environment` via temp-file + `mv`; the
  same shape should apply to profile.d.
- **Process-killing is unsolved.** No existing primitive locates PIDs
  holding files under a directory. Consumers fall back to "hope nothing
  is running", which on a CI runner VM is exactly the wrong assumption
  when an uninstall coincides with a running job.

## Scope

Add five new public functions to `Infrastructure.HyperV`, each acting
on a VM via the existing
[Invoke-SshClientCommand](../../../../Infrastructure.HyperV/Public/Ssh/Invoke-SshClientCommand.ps1)
primitive, all sudo'd, all idempotent, all matching the skip-unchanged
contract established by
[02 - skip-unchanged-on-copy](../02%20-%20skip-unchanged-on-copy/problem.md).

### `Expand-VmTarball`

Streams a tarball from the host into a VM and extracts it to a target
directory under sudo. Uses the existing
[Invoke-WithVmFileServer](../../../../Infrastructure.HyperV/Public/FileServer/Invoke-WithVmFileServer.ps1)
pattern so the tarball never lands as a file on the VM disk.

Parameters: `-Vm`, `-TarballPath` (host path), `-Destination` (guest
path, must be absolute), `-StripComponents` (optional, integer,
default 0).

Algorithm, one SSH round-trip after the file server is up:

1. `curl` the tarball from the host file server into a pipe.
2. Pipe straight into `tar -xzf - -C <tempdir>` under sudo, with
   `--strip-components=<N>` if requested.
3. `mv` the tempdir into `<destination>` atomically (parent must
   already exist; the cmdlet creates the parent if missing).
4. Skip the whole operation when `<destination>` exists and contains a
   marker file recording the same source tarball SHA-256 (the
   skip-unchanged check; SHA-256 computed host-side and written into
   `<destination>/.infra-hyperv-tarball.sha256` on success).

### `New-VmSymlink` / `Remove-VmSymlink`

Idempotent symlink management under sudo.

`New-VmSymlink -Vm -Path -Target`:

1. If `<Path>` exists and is a symlink with the same `<Target>`,
   no-op (skip-unchanged).
2. If `<Path>` exists and is anything else (regular file, dir, wrong
   target), fail with a clear error - the caller has not declared
   ownership of this path.
3. Otherwise, `ln -s <Target> <Path>` under sudo. Parent must exist.

`Remove-VmSymlink -Vm -Path`:

1. If `<Path>` does not exist, no-op.
2. If `<Path>` is a symlink, `rm` it (regardless of where it points).
3. If `<Path>` is not a symlink, fail - the cmdlet does not delete
   regular files.

### `Set-VmProfileDScript` / `Remove-VmProfileDScript`

`/etc/profile.d/<name>.sh` management with atomic writes.

`Set-VmProfileDScript -Vm -Name -Content`:

1. `<Name>` is validated host-side: non-empty, matches
   `[A-Za-z0-9._-]+`, no path separators, no `.sh` suffix (added by
   the cmdlet). Target is `/etc/profile.d/<Name>.sh`.
2. Skip-unchanged: if the target exists and its content byte-for-byte
   equals `<Content>`, no-op.
3. Otherwise, write `<Content>` to a temp file in `/etc/profile.d/`,
   `chmod 0644`, `chown root:root`, `mv` atomically over the target.

`Remove-VmProfileDScript -Vm -Name`:

1. Same `<Name>` validation.
2. If `/etc/profile.d/<Name>.sh` exists, `rm` it under sudo. Otherwise
   no-op.

### `Remove-VmDirectory`

Removes a directory tree under sudo, with a host-side allowlist guard
so the primitive cannot be turned into `rm -rf /` by a buggy caller.

Parameters: `-Vm`, `-Path` (guest path).

Algorithm:

1. Validate `<Path>` host-side: absolute, non-empty, no `..` segments,
   under one of an allowlisted parent set
   (`/opt`, `/var/lib/infra-provisioner`, `/usr/local/share`).
   Reject `<Path>` equal to an allowlisted parent itself (no
   `/opt` -> `/`). Reject literal `/`, `/usr`, `/etc`, `/home`,
   `/var`, `/root`, `/boot`, `/lib*`, `/sbin`, `/bin`, `/proc`,
   `/sys`, `/dev`.
2. If `<Path>` does not exist on the VM, no-op.
3. If `<Path>` exists but is not a directory, fail - the cmdlet does
   not delete regular files or symlinks (`Remove-VmSymlink` does
   that).
4. `sudo rm -rf <Path>` under `set -e`.

The allowlist is the contract: callers who need to remove a directory
outside the allowlist must extend it deliberately in this module. That
forces the security review to land here, not be re-derived per
consumer.

### `Stop-VmProcessesUsingPath`

Locates and stops processes holding files under a directory.

`Stop-VmProcessesUsingPath -Vm -Path -GraceSeconds`:

1. `<Path>` validated host-side: absolute, non-empty.
2. Remote script under `set -e`:
   - Find PIDs via `lsof +D <Path>` (or `fuser -m`, fallback to
     `/proc/*/exe` and `/proc/*/maps` scans for environments without
     `lsof`/`fuser`).
   - `kill -TERM` each PID. Wait up to `<GraceSeconds>` for them to
     exit, polling at 0.5s intervals.
   - `kill -KILL` any survivors. Wait up to 5 seconds for kernel to
     reap them.
3. Returns a structured result: `{ TerminatedPids, KilledPids,
   StillAlive }`. `StillAlive` non-empty is a non-zero exit (the
   kernel could not reap them within the budget; the caller decides
   whether to retry or fail).

## Out of scope

- **Non-Linux guests.** All four primitives assume an
  Ubuntu/Debian-shaped Linux guest (sudo, `/etc/profile.d`,
  `/usr/local/bin`, `lsof`). Windows-guest VMs are not produced by
  consumers of this repo.
- **Multi-tarball / archive formats other than `.tar.gz`.** `.zip`,
  `.tar.xz`, `.tar.bz2` are deferred. The streaming-extract algorithm
  generalises, but no consumer needs the alternatives in v1.
- **Symlink chains and indirection.** `New-VmSymlink` writes one
  symlink pointing at one target. "Manage this `update-alternatives`
  group" is a separate concern.
- **Reading profile.d scripts back.** Consumers that need to know
  "what did I write" rely on their own records (the
  [Vm-Provisioner manifest](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/42%20-%20dotnet%20sdk/problem.md#sidecar-manifests)
  pattern). This module does not enumerate profile.d.
- **Process-tree handling beyond direct holders.** `lsof +D` finds
  processes with files **open** under `<Path>` or with `<Path>` as
  cwd / exe. Daemonised child processes that no longer hold any file
  under `<Path>` are not killed. Consumers who need a "stop everything
  this software ever spawned" semantic must layer their own tracking
  (e.g. cgroups, systemd scopes) on top.
- **Coordination with workload schedulers.** The cmdlet does not know
  about the GitHub Actions runner, systemd jobs, or any other
  workload manager. Killing processes mid-job will make those jobs
  fail. Operators drain workloads via the relevant repo
  (`Infrastructure-GitHubRunners` for actions runners) before
  invoking reconciliation that triggers process kills.
- **Encrypted profile.d content.** Same rationale as
  [Set-VmEnvironmentVariables](../../../../Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1):
  secrets do not belong in world-readable scripts.
  `Infrastructure-Secrets` is the surface for those.

## Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Where the tarball lives during install | Streamed via host file server, never on VM disk | Matches the existing `Invoke-WithVmFileServer` pattern. Keeps the VM disk free of large temporary artifacts and lets the cmdlet work even when the VM has minimal free space. Rejected alternative: `Copy-VmFiles` then `tar`, which doubles disk usage and needs a cleanup step. |
| Atomic extraction | Extract to tempdir under target's parent, then `mv` | A crash mid-extract must never leave a half-extracted `<destination>/` that future runs would mistake for a successful install. `mv` within the same filesystem is atomic on Linux. Rejected: extract directly into `<destination>` then rename a flag file - a flag file does not protect against the kernel killing `tar` between extraction of file N and file N+1. |
| Skip-unchanged for tarball | SHA-256 of source tarball stored in `<destination>/.infra-hyperv-tarball.sha256` | The marker is small, host-computed once, and survives across runs. The whole-tree byte comparison alternative is impractical (large trees, file timestamps). SHA-256 over the tarball is sufficient because the tarball is the input contract; extraction is deterministic. |
| `New-VmSymlink` refusing to overwrite non-symlinks | Hard fail when `<Path>` is a regular file / dir | Silently replacing a real file with a symlink is the worst class of bug - data loss with no audit trail. The cmdlet is a primitive; the caller (orchestrator / provider) decides what to do with the conflict. |
| `Remove-VmSymlink` refusing to delete non-symlinks | Hard fail when `<Path>` exists but is not a symlink | Same rationale, inverted. The cmdlet does not delete regular files. A separate `Remove-VmPath` or similar would be its own decision; this one is symlink-only by name and behaviour. |
| Profile.d naming | `<Name>` is a base name, cmdlet appends `.sh` | Forces the convention; prevents caller from passing `/etc/profile.d/foo.sh` (with path traversal risk) or `foo` (which `pam_env` would not source). The validation regex is intentionally narrow. |
| Profile.d atomicity | Temp file in same dir + `mv` under `set -e` | Same shape as [Set-VmEnvironmentVariables](../../../../Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1). A crash mid-write must never leave a truncated profile.d script - login shells would `source` the truncated half and fail. |
| Process-find tool | `lsof +D <Path>` primary, `/proc` scan fallback | `lsof` is on default Ubuntu Server. The fallback (read `/proc/*/exe`, `/proc/*/maps`, `/proc/*/cwd`) exists for minimal images / containers in the test bed where `lsof` may be absent. The cmdlet picks the available one at runtime. |
| Grace window default | Caller-supplied, no implicit default | The right grace window depends on the workload (a JDK compiler exits in seconds; a long-running dotnet test could need a minute). No default is safer than a wrong default. The reconciler caller in `Vm-Provisioner` will surface this as a config knob. |
| Process result shape | Structured object with three PID lists | Lets the caller log which processes died vs were killed vs survived. A boolean "did it work" is too coarse for an unattended provisioning loop where operators need to audit kills after the fact. |
| `Remove-VmDirectory` allowlist | Host-side path-prefix allowlist + hard-coded denylist of system dirs | A bare `Remove-VmPath` is a footgun: a typo in a caller's `$installDir` could `rm -rf /`. The allowlist constrains the blast radius to areas the provisioner legitimately owns; extending it is a deliberate edit to this module that goes through review. Denylist of system paths is belt-and-braces against a caller passing `/usr/local/share/../etc`. |
| `Remove-VmDirectory` refusing non-directories | Hard fail when `<Path>` exists but is a file or symlink | Same rationale as `New-VmSymlink` refusing to overwrite a regular file: a primitive that silently does the wrong kind of removal is the worst class of bug. The caller routes to `Remove-VmSymlink` for symlinks; regular files are not a supported case (no current consumer needs it). |
| Skip-unchanged switch shape | `-NoSkipUnchanged` on every cmdlet | Same opt-out shape as [Copy-VmFiles](../02%20-%20skip-unchanged-on-copy/problem.md) and `Set-VmEnvironmentVariables`. Consistency across the module's public surface. |
| Sudo handling | All four cmdlets assume passwordless sudo for the SSH user | Same assumption every other write-side primitive in this module makes ([Set-VmEnvironmentVariables](../../../../Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1) included). The provisioner sets that up at first-boot via cloud-init; this module does not re-verify. |
| Public surface | Five cmdlet pairs (or families), all under existing or new `Public/` subfolders | `Expand-VmTarball` joins `Public/FileServer/`; `New-VmSymlink` / `Remove-VmSymlink` go under a new `Public/Symlinks/`; profile.d pair under new `Public/ProfileD/`; `Stop-VmProcessesUsingPath` under new `Public/Processes/`; `Remove-VmDirectory` under new `Public/Filesystem/`. Keeps the module's existing organisation principle (one concept per subfolder). |

## Acceptance criteria

### `Expand-VmTarball`

- Streams `<TarballPath>` from the host file server, extracts under
  sudo to `<Destination>`, with `--strip-components=<N>` honoured
  when supplied.
- A re-run with the same `<TarballPath>` (same SHA-256) is a no-op:
  no `tar` invocation, no `mv`, `<Destination>` mtime unchanged.
- A re-run with a different `<TarballPath>` re-extracts: the old
  `<Destination>` is replaced atomically; no intermediate state in
  which `<Destination>` is missing or half-populated.
- A crash partway through extraction leaves `<Destination>`
  unchanged (the tempdir is the one that is incomplete and is
  discarded on the next run).
- `<Destination>` ends up owned `root:root` with directory mode
  inherited from the tarball.
- `.infra-hyperv-tarball.sha256` is written inside `<Destination>`
  on success and is checked on subsequent calls.

### `New-VmSymlink` / `Remove-VmSymlink`

- `New-VmSymlink` creates `<Path>` as a symlink to `<Target>`,
  owned `root:root`.
- `New-VmSymlink` is a no-op when `<Path>` is already a symlink to
  the same `<Target>`.
- `New-VmSymlink` fails when `<Path>` exists as a regular file,
  directory, or symlink to a different target; the error names the
  conflict.
- `Remove-VmSymlink` removes `<Path>` when it is a symlink; is a
  no-op when `<Path>` does not exist; fails when `<Path>` exists
  but is not a symlink.

### `Set-VmProfileDScript` / `Remove-VmProfileDScript`

- `<Name>` validated host-side; invalid names rejected before SSH.
- `Set-VmProfileDScript` writes `/etc/profile.d/<Name>.sh` with
  the given content, owner `root:root`, mode `0644`, via temp file
  + `mv`.
- A re-run with identical content is a no-op (mtime unchanged).
- A crash partway through the write never leaves
  `/etc/profile.d/<Name>.sh` truncated (asserted by inspecting the
  script shape: temp file + `mv` under `set -e`).
- `Remove-VmProfileDScript` removes the file when present, no-ops
  when absent.

### `Remove-VmDirectory`

- Removes `<Path>` recursively under sudo when it exists and is a
  directory.
- Is a no-op when `<Path>` does not exist.
- Fails (before any SSH I/O) when `<Path>` is not absolute, contains
  `..`, is not under the allowlist, or matches a denylisted system
  dir.
- Fails when `<Path>` exists on the VM but is a regular file or
  symlink; the error names what was found.
- Extending the allowlist requires editing
  `Remove-VmDirectory.ps1` (no per-VM config knob); the test suite
  asserts the current allowlist by enumeration so additions are
  visible in diffs.

### `Stop-VmProcessesUsingPath`

- Returns `{ TerminatedPids, KilledPids, StillAlive }`.
- A process holding a file under `<Path>` receives `SIGTERM` first;
  if it exits within `<GraceSeconds>` its PID is in
  `TerminatedPids`.
- A process that does not exit within `<GraceSeconds>` receives
  `SIGKILL`; its PID is in `KilledPids` once reaped.
- A process that survives both (e.g. uninterruptible sleep) is
  reported in `StillAlive` and the cmdlet exits non-zero.
- No process running outside `<Path>` is touched (asserted with a
  control process whose PID is not in any of the three lists).
- When no process holds files under `<Path>`, all three lists are
  empty and the cmdlet exits zero with no `kill` invocations.

### Shared / module-level

- Module manifest exports all new functions; the existing
  `Module.Tests.ps1` parity check (`FunctionsToExport` vs
  `Export-ModuleMember`) continues to pass.
- README documents the four cmdlets alongside the existing
  transport primitives, with a short rationale ("install / uninstall
  primitives used by toolchain reconcilers in downstream repos") and
  a pointer to
  [Infrastructure-Vm-Provisioner/42 - dotnet sdk](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/42%20-%20dotnet%20sdk/problem.md)
  as the first consumer.
- Unit tests pin the emitted script shape for each cmdlet (sentinel
  handling where applicable, `set -e`, temp-file + `mv`, owner /
  mode commands, skip-unchanged short-circuit, sudo prefix).
- Integration tests against the Docker target cover, per cmdlet:
  first-run create, identical re-run is a no-op, removal /
  non-existent / conflict cases, atomicity assertion (script
  inspection), and - for `Stop-VmProcessesUsingPath` - all three
  outcome lists exercised with controlled fixture processes.

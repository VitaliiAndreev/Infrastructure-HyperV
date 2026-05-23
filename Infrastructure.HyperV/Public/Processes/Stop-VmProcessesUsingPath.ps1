<#
.SYNOPSIS
    Terminates every process on a Hyper-V VM whose open files, cwd,
    executable, or memory mappings touch a given filesystem path,
    escalating from SIGTERM to SIGKILL, and reports the outcome.

.DESCRIPTION
    Single-round-trip primitive used by uninstall flows that need to
    free a directory tree before removing it. The cmdlet scans the VM
    for processes that hold <Path> open, sends SIGTERM, then polls
    `kill -0` at 0.5s intervals up to <GraceSeconds>. Any SIGTERM
    survivors are sent SIGKILL and polled for up to 5 seconds (the
    kernel reap window); the results are split into TerminatedPids
    (exited under SIGTERM), KilledPids (reaped after SIGKILL), and
    StillAlive (unreaped even after SIGKILL - typically uninterruptible
    sleep, e.g. blocked in disk I/O or an NFS RPC). A non-empty
    StillAlive causes the cmdlet to throw (exit 64 on the remote side).

    The remote scanner prefers `lsof +D` (catches open files, mmaps,
    cwd, exe), falls back to `fuser -m` (open files + mmaps under the
    mountpoint), and finally walks /proc/*/exe, /proc/*/cwd, and
    /proc/*/maps directly. Three branches because none of the three is
    universally available across the minimal Ubuntu images this module
    targets and the proc-walk fallback is the last-resort that needs
    nothing but coreutils + grep + awk.

    Path is validated host-side before any SSH call: must be a
    non-empty absolute path with no `..` segments, no NUL byte, and no
    single quote (the remote script embeds it inside a single-quoted
    bash assignment, matching the rest of the module).

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - this function neither connects nor disposes it.

.PARAMETER Path
    Absolute path on the VM whose holders should be terminated. May be
    a file or a directory; the scanner treats it as a tree root.

.PARAMETER GraceSeconds
    Non-negative integer. The cmdlet polls `kill -0` against the
    SIGTERM'd PIDs at 0.5s intervals for at most this many seconds.
    GraceSeconds = 0 skips the poll loop entirely - PIDs are
    classified as "still alive" immediately if they have not already
    exited by the time the kill returns.

.OUTPUTS
    PSCustomObject with three integer-array properties:
      - TerminatedPids: PIDs that exited within the grace window.
      - KilledPids    : PIDs that survived SIGTERM but were reaped
                        within the 5-second SIGKILL window.
      - StillAlive    : PIDs that survived SIGKILL too (typically
                        stuck in uninterruptible sleep). Non-empty
                        StillAlive causes the cmdlet to throw.

.EXAMPLE
    Stop-VmProcessesUsingPath -SshClient $ssh -Path '/opt/jdk-21' -GraceSeconds 5

.NOTES
    On-VM commands run under sudo. The caller is responsible for
    ensuring the SSH user has password-less sudo.
#>
function Stop-VmProcessesUsingPath {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [int] $GraceSeconds
    )

    # Host-side validation. Mirrors Remove-VmDirectory's path rules so
    # an entire install/uninstall flow that pre-validates against one
    # cmdlet's contract will not be surprised by another.
    if ([string]::IsNullOrEmpty($Path)) {
        throw "Stop-VmProcessesUsingPath: -Path must be a non-empty string."
    }
    if (-not $Path.StartsWith('/')) {
        throw ("Stop-VmProcessesUsingPath: -Path '$Path' must be an " +
            "absolute path (start with '/').")
    }
    if ($Path.Contains([char]0)) {
        throw "Stop-VmProcessesUsingPath: -Path contains a NUL byte."
    }
    if ($Path.Contains("'")) {
        throw ("Stop-VmProcessesUsingPath: -Path '$Path' contains a " +
            "single quote, which is not allowed.")
    }
    if ($Path.Split('/') -contains '..') {
        throw ("Stop-VmProcessesUsingPath: -Path '$Path' contains a " +
            "'..' segment.")
    }
    if ($GraceSeconds -lt 0) {
        throw ("Stop-VmProcessesUsingPath: -GraceSeconds must be " +
            "non-negative (got $GraceSeconds).")
    }

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }

    # EX_USAGE-adjacent exit code used module-wide for "remote side
    # ran fine but the operation could not complete fully" - here, one
    # or more processes survived SIGTERM.
    $survivorExitCode = 64

    # Poll loop is generated only when grace > 0. Plan calls this out
    # explicitly: GraceSeconds=0 skips waiting entirely. We still
    # classify after the kill so terminated-immediately is recorded.
    $pollLoop = if ($GraceSeconds -gt 0) {
        $totalTenths = $GraceSeconds * 10
        @"

elapsed=0
while [ "`$elapsed" -lt $totalTenths ]; do
    any_alive=0
    for pid in `$initial; do
        if sudo kill -0 "`$pid" 2>/dev/null; then
            any_alive=1
            break
        fi
    done
    if [ "`$any_alive" -eq 0 ]; then break; fi
    sleep 0.5
    elapsed=`$((elapsed + 5))
done
"@
    } else { '' }

    # SIGKILL reap window is fixed at 5s (10 polls * 0.5s). The kernel
    # reaps a SIGKILL'd process within microseconds unless the task is
    # stuck in uninterruptible sleep (D state) waiting on disk I/O,
    # NFS, or similar - cases that 5s will not unblock either, so a
    # longer wait would just delay the inevitable StillAlive report.
    $reapTenths = 50
    $script = @"
set -euo pipefail
path='$Path'
pids=''

if command -v lsof >/dev/null 2>&1; then
    pids=`$(sudo lsof -t +D "`$path" 2>/dev/null | sort -un | tr '\n' ' ' || true)
elif command -v fuser >/dev/null 2>&1; then
    pids=`$(sudo fuser -m "`$path" 2>/dev/null | tr -s ' \t\n' '\n' | grep -v '^`$' | sort -un | tr '\n' ' ' || true)
else
    found=''
    for d in /proc/[0-9]*; do
        [ -d "`$d" ] || continue
        pid=`${d#/proc/}
        match=0
        for link in exe cwd; do
            t=`$(sudo readlink "`$d/`$link" 2>/dev/null || true)
            case "`$t" in
                "`$path"|"`$path"/*) match=1; break ;;
            esac
        done
        if [ `$match -eq 0 ] && [ -r "`$d/maps" ]; then
            if sudo awk -v p="`$path" '`$NF == p || index(`$NF, p"/") == 1 { f=1; exit } END { exit !f }' "`$d/maps" 2>/dev/null; then
                match=1
            fi
        fi
        if [ `$match -eq 1 ]; then found="`$found `$pid"; fi
    done
    pids=`$(printf '%s\n' `$found | grep -v '^`$' | sort -un | tr '\n' ' ' || true)
fi

pids=`$(echo `$pids | xargs || true)

if [ -z "`$pids" ]; then
    echo "TERMINATED= KILLED= STILL_ALIVE="
    exit 0
fi

initial="`$pids"
echo "`$pids" | xargs -r sudo kill -TERM 2>/dev/null || true
$pollLoop
terminated=''
sigterm_survivors=''
for pid in `$initial; do
    if sudo kill -0 "`$pid" 2>/dev/null; then
        sigterm_survivors="`$sigterm_survivors `$pid"
    else
        terminated="`$terminated `$pid"
    fi
done

# SIGKILL escalation. Only survivors are signalled - SIGKILL to a PID
# that has already exited is harmless but kill returns non-zero and
# would mask real failures under `set -e` without the `|| true`.
killed=''
still_alive=''
if [ -n "`$sigterm_survivors" ]; then
    echo "`$sigterm_survivors" | xargs -r sudo kill -KILL 2>/dev/null || true

    kelapsed=0
    while [ "`$kelapsed" -lt $reapTenths ]; do
        any_alive=0
        for pid in `$sigterm_survivors; do
            if sudo kill -0 "`$pid" 2>/dev/null; then
                any_alive=1
                break
            fi
        done
        if [ "`$any_alive" -eq 0 ]; then break; fi
        sleep 0.5
        kelapsed=`$((kelapsed + 5))
    done

    for pid in `$sigterm_survivors; do
        if sudo kill -0 "`$pid" 2>/dev/null; then
            still_alive="`$still_alive `$pid"
        else
            killed="`$killed `$pid"
        fi
    done
fi

terminated=`$(echo `$terminated | xargs || true)
killed=`$(echo `$killed | xargs || true)
still_alive=`$(echo `$still_alive | xargs || true)

echo "TERMINATED=`$terminated KILLED=`$killed STILL_ALIVE=`$still_alive"

if [ -n "`$still_alive" ]; then
    exit $survivorExitCode
fi
exit 0
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # the rest of the module.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script

    # Locate the result line in stdout. The script always prints
    # exactly one TERMINATED= line; missing it means the remote bash
    # crashed before reaching the report - surface stderr in that case.
    $resultLine = $null
    if ($result.Output) {
        foreach ($line in ($result.Output -split "`n")) {
            if ($line -match '^TERMINATED=') { $resultLine = $line; break }
        }
    }

    if ($null -eq $resultLine) {
        throw ("Stop-VmProcessesUsingPath failed (vm: $vmHost, path: $Path, " +
            "exit $($result.ExitStatus)): no result line in stdout. " +
            "stdout: $($result.Output)  stderr: $($result.Error)")
    }

    # Parse "TERMINATED=<a b c> KILLED=<...> STILL_ALIVE=<...>". Each
    # capture is lazy so the engine can find the literal field
    # separators even when a list contains spaces.
    if ($resultLine -notmatch '^TERMINATED=(?<t>.*?)\s+KILLED=(?<k>.*?)\s+STILL_ALIVE=(?<s>.*?)\s*$') {
        throw ("Stop-VmProcessesUsingPath failed (vm: $vmHost, path: $Path): " +
            "unparseable result line '$resultLine'.")
    }

    $terminatedPids = @()
    $killedPids     = @()
    $stillAlive     = @()
    if ($Matches['t'].Trim()) {
        $terminatedPids = @($Matches['t'].Trim() -split '\s+' | ForEach-Object { [int]$_ })
    }
    if ($Matches['k'].Trim()) {
        $killedPids = @($Matches['k'].Trim() -split '\s+' | ForEach-Object { [int]$_ })
    }
    if ($Matches['s'].Trim()) {
        $stillAlive = @($Matches['s'].Trim() -split '\s+' | ForEach-Object { [int]$_ })
    }

    $resultObject = [PSCustomObject]@{
        TerminatedPids = $terminatedPids
        KilledPids     = $killedPids
        StillAlive     = $stillAlive
    }

    if ($result.ExitStatus -eq $survivorExitCode -or $stillAlive.Count -gt 0) {
        throw ("Stop-VmProcessesUsingPath: $($stillAlive.Count) process(es) " +
            "still hold '$Path' on VM $vmHost after SIGTERM + " +
            "$GraceSeconds`s grace + SIGKILL + 5s reap. " +
            "StillAlive: $($stillAlive -join ', '). " +
            "Killed: $($killedPids -join ', '). " +
            "Terminated: $($terminatedPids -join ', ').")
    }

    if ($result.ExitStatus -ne 0) {
        throw ("Stop-VmProcessesUsingPath failed (vm: $vmHost, path: $Path, " +
            "exit $($result.ExitStatus)). stdout: $($result.Output)  " +
            "stderr: $($result.Error)")
    }

    return $resultObject
}

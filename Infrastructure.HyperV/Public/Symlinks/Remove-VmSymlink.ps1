<#
.SYNOPSIS
    Removes a symbolic link from a Hyper-V VM under sudo.

.DESCRIPTION
    Single-round-trip primitive that removes the symlink at <Path>.
    Idempotent: no-op when <Path> does not exist. Refuses to delete
    anything that is not a symlink (regular file, directory, other)
    so the cmdlet cannot be used to silently wipe real data through
    a typo in <Path>. The conflict refusal mirrors New-VmSymlink's
    contract on the install side.

    The remote script runs under `set -e` and uses exit code 65
    (EX_DATAERR from sysexits) to signal a conflict back to the host
    layer, which surfaces it as a PowerShell exception naming the path
    and the observed file type.

    Path is validated host-side before any SSH call: must be a
    non-empty absolute path with no `..` segments, no NUL byte, and no
    single quote (the remote script embeds it inside a single-quoted
    bash assignment).

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - this function neither connects nor disposes it.

.PARAMETER Path
    Absolute path on the VM of the symlink to remove.

.EXAMPLE
    Remove-VmSymlink -SshClient $ssh -Path '/usr/local/bin/foo'

.NOTES
    The on-VM commands run under sudo so the function can remove
    links in privileged locations regardless of which user the SSH
    client authenticated as. The caller is responsible for ensuring
    that user has password-less sudo.
#>
function Remove-VmSymlink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Path
    )

    # Host-side path validation. <Path> embeds into a single-quoted
    # bash assignment in the emitted script, so a single quote would
    # break out of the quoting and let the value be interpreted as
    # shell syntax. NUL and `..` are rejected for the usual reasons
    # (truncation in C-string parsers, traversal). The validator
    # intentionally runs before any SSH call so malformed input never
    # touches the wire.
    if ([string]::IsNullOrEmpty($Path)) {
        throw "Remove-VmSymlink: -Path must be a non-empty string."
    }
    if (-not $Path.StartsWith('/')) {
        throw "Remove-VmSymlink: -Path '$Path' must be an absolute path (start with '/')."
    }
    if ($Path.Contains([char]0)) {
        throw "Remove-VmSymlink: -Path contains a NUL byte."
    }
    if ($Path.Contains("'")) {
        throw "Remove-VmSymlink: -Path '$Path' contains a single quote, which is not allowed."
    }
    if ($Path.Split('/') -contains '..') {
        throw "Remove-VmSymlink: -Path '$Path' contains a '..' segment."
    }

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }

    # EX_DATAERR from sysexits.h - used as the conflict signal so the
    # host layer can distinguish "wrong file type at Path" from generic
    # remote failures (which surface as their own exit codes).
    $conflictExitCode = 65

    $script = @"
set -e
path='$Path'
if [ ! -e "`$path" ] && [ ! -L "`$path" ]; then
    exit 0
fi
if [ ! -L "`$path" ]; then
    if [ -d "`$path" ]; then
        echo "exists as directory" >&2
    elif [ -f "`$path" ]; then
        echo "exists as regular file" >&2
    else
        echo "exists as other (not a regular file, directory, or symlink)" >&2
    fi
    exit $conflictExitCode
fi
sudo rm "`$path"
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # the rest of the module.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script

    if ($result.ExitStatus -eq 0) { return }

    if ($result.ExitStatus -eq $conflictExitCode) {
        throw ("Remove-VmSymlink: conflict at '$Path' on VM $vmHost - " +
            "$($result.Error.Trim()) (refusing to remove a non-symlink).")
    }

    throw ("Remove-VmSymlink failed (vm: $vmHost, path: $Path, " +
        "exit $($result.ExitStatus)). stdout: $($result.Output)  stderr: $($result.Error)")
}

<#
.SYNOPSIS
    Stages a host-side gzipped tarball to a Hyper-V VM and extracts it
    into <Destination> atomically under sudo.

.DESCRIPTION
    Single-round-trip primitive that joins the existing FileServer family
    (Add-VmFileServerFile, Invoke-WithVmFileServer) with a remote
    extract-then-swap step. The cmdlet performs the host-side stage, then
    one SSH call that:

      1. Creates a sibling tempdir under the destination's parent
         (`<parent>/.expand.XXXXXX`).
      2. Streams the tarball over HTTP and pipes the bytes into
         `sudo tar -xzf -` with the caller-supplied `--strip-components`.
      3. Removes any existing object at <Destination> (file, symlink, or
         directory tree).
      4. Renames the tempdir to <Destination>.

    The mktemp + extract + mv sequence is what makes the swap atomic from
    any observer's point of view: <Destination> either points at the old
    tree or the freshly extracted tree, never at a half-populated dir.
    The cmdlet does NOT install a trap for crash cleanup - if the remote
    script is killed between mktemp and mv, the tempdir is left as a
    sibling and the next clean run finds <Destination> unchanged. That
    is intentional: making cleanup the caller's problem keeps the
    primitive single-purpose and is what the integration test suite
    verifies.

    Skip-unchanged via a SHA-256 marker file is layered on in the
    follow-up step; this commit always extracts.

    Path validation is host-side and runs before any staging or SSH:
    <Destination> must be a non-empty absolute path with no `..`
    segments, no NUL byte, and no single quote (the remote script
    embeds it inside a single-quoted bash assignment, matching the rest
    of the module). <TarballPath> must exist on the host so the
    Add-VmFileServerFile call cannot fail late in the flow.
    <StripComponents> is a non-negative integer that flows through to
    `tar --strip-components` verbatim.

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - this function neither connects nor disposes it.

.PARAMETER Server
    The file server handle returned by Start-VmFileServer (or received as
    the script-block argument from Invoke-WithVmFileServer). Forwarded
    verbatim to Add-VmFileServerFile to stage <TarballPath>.

.PARAMETER TarballPath
    Absolute path on the Windows host to a gzipped tar archive
    (e.g. `E:\cache\jdk-21.tar.gz`). The file is staged into the live
    server and pulled down over HTTP by the VM.

.PARAMETER Destination
    Absolute path on the VM where the extracted tree should live. The
    parent directory is created if missing; the destination itself is
    replaced atomically (rm -rf then mv from a sibling tempdir).

.PARAMETER StripComponents
    Non-negative integer passed to `tar --strip-components`. Defaults to
    0 (no stripping). Set to 1 to discard a single wrapper directory
    inside the tarball.

.EXAMPLE
    Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
        param($server)
        Expand-VmTarball -SshClient $ssh -Server $server `
            -TarballPath 'E:\cache\jdk-21.tar.gz' `
            -Destination '/opt/jdk-21' -StripComponents 1
    }

.NOTES
    On-VM commands run under sudo so the function can write to
    privileged locations regardless of which user the SSH client
    authenticated as. The caller is responsible for ensuring that user
    has password-less sudo.
#>
function Expand-VmTarball {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [PSCustomObject] $Server,

        [Parameter(Mandatory)]
        [string] $TarballPath,

        [Parameter(Mandatory)]
        [string] $Destination,

        [Parameter()]
        [int] $StripComponents = 0
    )

    # Host-side validation. Runs before any staging / SSH so malformed
    # input never reaches the wire and the file server is not asked to
    # stage a file we will refuse to use. The path rules match the rest
    # of the module: absolute, no `..`, no NUL, no single quote (the
    # value embeds into a single-quoted bash assignment in the emitted
    # script).
    if ([string]::IsNullOrEmpty($Destination)) {
        throw "Expand-VmTarball: -Destination must be a non-empty string."
    }
    if (-not $Destination.StartsWith('/')) {
        throw ("Expand-VmTarball: -Destination '$Destination' must be an " +
            "absolute path (start with '/').")
    }
    if ($Destination.Contains([char]0)) {
        throw "Expand-VmTarball: -Destination contains a NUL byte."
    }
    if ($Destination.Contains("'")) {
        throw ("Expand-VmTarball: -Destination '$Destination' contains a " +
            "single quote, which is not allowed.")
    }
    if ($Destination.Split('/') -contains '..') {
        throw ("Expand-VmTarball: -Destination '$Destination' contains a " +
            "'..' segment.")
    }
    if ($StripComponents -lt 0) {
        throw ("Expand-VmTarball: -StripComponents must be non-negative " +
            "(got $StripComponents).")
    }
    if (-not (Test-Path -LiteralPath $TarballPath)) {
        throw "Expand-VmTarball: -TarballPath '$TarballPath' does not exist on the host."
    }

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }

    # Stage the tarball through the live file server. This must come
    # after host-side validation so a malformed Destination does not
    # leave a staged copy behind.
    $url = Add-VmFileServerFile -Server $Server -LocalPath $TarballPath

    # The mktemp template lives next to <Destination> (same filesystem)
    # so the final `mv` is a single rename inode operation rather than
    # a cross-device copy. The leading dot keeps the partial tree out
    # of casual `ls` output while it is being populated.
    $script = @"
set -euo pipefail
destination='$Destination'
url='$url'
strip='$StripComponents'
parent="`$(dirname "`$destination")"
sudo mkdir -p "`$parent"
tmpdir="`$(sudo mktemp -d "`$parent/.expand.XXXXXX")"
curl -fsSL "`$url" | sudo tar -xzf - -C "`$tmpdir" --strip-components="`$strip"
if [ -e "`$destination" ] || [ -L "`$destination" ]; then
    sudo rm -rf -- "`$destination"
fi
sudo mv "`$tmpdir" "`$destination"
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # the rest of the module.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script

    if ($result.ExitStatus -eq 0) { return }

    throw ("Expand-VmTarball failed (vm: $vmHost, tarball: $TarballPath, " +
        "destination: $Destination, exit $($result.ExitStatus)). " +
        "stdout: $($result.Output)  stderr: $($result.Error)")
}

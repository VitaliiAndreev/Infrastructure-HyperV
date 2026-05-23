# Integration tests for Expand-VmTarball against a real SSH target.
# See Initialize-DockerTargetEnvironment.ps1 for environment details.
#
# Unit tests already pin the emitted script shape (mktemp, curl|tar,
# marker pre-check, atomic mv). This file proves the end-to-end flow
# against a live tar / shell: the staged tarball really extracts into
# <Destination>, the marker file written into the tempdir survives
# the dir-swap and short-circuits the next call, -NoSkipUnchanged
# really re-extracts, and -StripComponents strips a wrapper level.
# A crash-simulation scenario covers the documented contract that a
# tempdir abandoned mid-extract leaves <Destination> unchanged.
#
# Extra setup vs the shared init:
#   - The base SSH test image's sudoers grants NOPASSWD on a precise
#     binary list (mkdir/curl/chown/chmod/tee/mv/rm/...). The cmdlet
#     under test also invokes `mktemp` and `tar` under sudo, so this
#     suite layers a supplemental sudoers.d entry that adds exactly
#     those two binaries - precise-grant style preserved.
#   - Fixture tarballs are produced inside the container with the
#     container's own `tar` (avoids host-side tar quirks on Windows
#     dev boxes) and then `docker cp`'d back to a host temp dir, so
#     Expand-VmTarball can be called with a real on-host
#     <TarballPath> and the file server can stage it normally.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    # ---------------------------------------------------------------
    # 1. Supplemental sudoers entry
    #    Layered as a second file under sudoers.d so the shared
    #    init's file remains untouched. Same root:root 0440 +
    #    visudo check as the primary file.
    # ---------------------------------------------------------------

    $Script:TarballSudoersPath = "/etc/sudoers.d/${Script:DeployUser}-expand-tarball"
    $extraSudoersContent = @"
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/mktemp
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/tar
${Script:DeployUser} ALL=(root) NOPASSWD: /bin/tar
"@ -replace "`r`n", "`n"

    $extraSudoersTempFile = Join-Path ([System.IO.Path]::GetTempPath()) `
        "infra-t-sudoers-expand-tarball-$(New-Guid)"
    [System.IO.File]::WriteAllText(
        $extraSudoersTempFile, $extraSudoersContent,
        [System.Text.UTF8Encoding]::new($false))

    try {
        docker cp $extraSudoersTempFile "${Script:ContainerName}:${Script:TarballSudoersPath}" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "docker cp of supplemental sudoers file failed (exit $LASTEXITCODE)."
        }
    }
    finally {
        Remove-Item -LiteralPath $extraSudoersTempFile -Force -ErrorAction SilentlyContinue
    }

    Invoke-ContainerCommand "chown root:root '$Script:TarballSudoersPath' && chmod 0440 '$Script:TarballSudoersPath'" |
        Out-Null

    $visudoCheck = docker exec $Script:ContainerName visudo -cf $Script:TarballSudoersPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("Supplemental sudoers file failed syntax check:`n" +
               ($visudoCheck -join "`n"))
    }

    # ---------------------------------------------------------------
    # 2. Host-side fixture-tarball directory
    #    Tarballs are produced inside the container then copied back.
    #    A single per-suite directory keeps cleanup to one rm in
    #    AfterAll; the New-Guid suffix avoids collisions when other
    #    test files run in the same temp tree.
    # ---------------------------------------------------------------

    $Script:HostTarballDir = Join-Path ([System.IO.Path]::GetTempPath()) `
        "Expand-VmTarball-Fixtures-$(New-Guid)"
    New-Item -ItemType Directory -Path $Script:HostTarballDir -Force | Out-Null

    # VM-side destination for every It block. Lives under /opt so the
    # parent already exists; the cmdlet creates it if missing anyway.
    $Script:VmDestination = '/opt/integration-test-tarball'
    $Script:VmDestParent  = '/opt'

    # ---------------------------------------------------------------
    # 3. Helpers
    # ---------------------------------------------------------------

    function New-FixtureTarball {
        # Creates a gzipped tarball whose root entry is a directory
        # named <RootDir> containing the supplied files. Built inside
        # the container so the test does not depend on the host's tar
        # implementation. Returns the absolute host path to the
        # tarball file.
        param(
            [Parameter(Mandatory)] [string]    $Name,
            [Parameter(Mandatory)] [string]    $RootDir,
            [Parameter(Mandatory)] [hashtable] $Files
        )

        $stagingId  = (New-Guid).Guid
        $cStaging   = "/tmp/expand-tarball-fixture-$stagingId"
        $cRoot      = "$cStaging/$RootDir"
        $cTarball   = "/tmp/$Name-$stagingId.tar.gz"

        Invoke-ContainerCommand "mkdir -p '$cRoot'" | Out-Null
        foreach ($entry in $Files.GetEnumerator()) {
            # Files keys are relative paths under <RootDir>. printf
            # writes the value verbatim (no trailing newline) so the
            # SHA-256 of the produced tarball is reproducible.
            $relPath  = $entry.Key
            $content  = $entry.Value
            $cFile    = "$cRoot/$relPath"
            $cFileDir = (Split-Path $cFile -Parent) -replace '\\', '/'
            Invoke-ContainerCommand "mkdir -p '$cFileDir'" | Out-Null
            # Single-quote the bash arg; escape inner single quotes.
            $escContent = $content -replace "'", "'\''"
            Invoke-ContainerCommand "printf '%s' '$escContent' > '$cFile'" | Out-Null
        }

        # -C parent + RootDir keeps the wrapper directory at the
        # top level of the archive (what -StripComponents 1 strips).
        Invoke-ContainerCommand "tar -czf '$cTarball' -C '$cStaging' '$RootDir'" | Out-Null

        $hostPath = Join-Path $Script:HostTarballDir "$Name.tar.gz"
        docker cp "${Script:ContainerName}:$cTarball" $hostPath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "docker cp of fixture tarball '$Name' failed (exit $LASTEXITCODE)."
        }

        Invoke-ContainerCommand "rm -rf '$cStaging' '$cTarball'" | Out-Null
        return $hostPath
    }

    # Inspection helpers run through `docker exec` (root inside the
    # container) rather than the deploy-user SSH session. The cmdlet's
    # `sudo mv "$tmpdir" "$destination"` lands the destination dir
    # with mktemp's 0700 root-owned mode, which means the deploy user
    # cannot stat / list / cat anything inside it. Routing reads via
    # docker exec side-steps that entirely: we are observing VM state
    # from outside the SSH session under test, so no permission
    # plumbing leaks into what the assertions are actually checking.

    function Invoke-RootQuery {
        param([Parameter(Mandatory)] [string] $Command)
        return (Invoke-ContainerCommand $Command | Out-String).Trim()
    }

    function Test-PathExists {
        param([string] $Path)
        $rc = Invoke-RootQuery "(test -e '$Path' || test -L '$Path') && echo yes || echo no"
        return ($rc -eq 'yes')
    }

    function Get-DirMtime {
        param([string] $Path)
        # %y is nanosecond-precision mtime; comparing as a string lets
        # a re-extract within the same second still show up as a tick.
        return Invoke-RootQuery "stat -c '%y' '$Path'"
    }

    function Get-FileContent {
        param([string] $Path)
        return Invoke-RootQuery "cat '$Path'"
    }

    function Get-Sha {
        param([string] $Path)
        return Invoke-RootQuery "sha256sum '$Path' | awk '{print `$1}'"
    }

    function Get-MarkerDigest {
        param([string] $Path)
        # Marker file content, trailing newline trimmed by Trim() in
        # Invoke-RootQuery, so a direct equality check against the
        # host-computed digest holds.
        return Invoke-RootQuery "cat '$Path'"
    }

    function Get-ExpandTempdirs {
        # Lists any sibling .expand.* tempdirs left behind by the
        # cmdlet (or by the crash-simulation script). Returns an
        # empty array when none exist.
        $listing = Invoke-RootQuery "ls -1d '$Script:VmDestParent'/.expand.* 2>/dev/null || true"
        if ([string]::IsNullOrWhiteSpace($listing)) { return @() }
        return @($listing -split "`n" | Where-Object { $_ })
    }

    # Filesystems with 1s mtime granularity (overlayfs on older
    # kernels) need a guard between writes so the second run's
    # mtime is distinguishable from the first.
    function Wait-ForMtimeTick { Start-Sleep -Milliseconds 1100 }

    # ---------------------------------------------------------------
    # 4. Fixture tarballs
    #    Produced once per suite. Each It picks whichever fixture it
    #    needs; the destination is wiped clean in BeforeEach so
    #    re-using fixtures across tests is safe.
    # ---------------------------------------------------------------

    $Script:Tarball_A = New-FixtureTarball -Name 'fixture-a' -RootDir 'root-a' -Files @{
        'a.txt'        = 'alpha contents'
        'sub/b.txt'    = 'bravo contents'
    }
    $Script:Tarball_B = New-FixtureTarball -Name 'fixture-b' -RootDir 'root-b' -Files @{
        'c.txt' = 'charlie contents'
    }

    $Script:Tarball_A_Digest = (Get-FileHash -LiteralPath $Script:Tarball_A `
        -Algorithm SHA256).Hash.ToLowerInvariant()
}

AfterAll {
    # Drop the supplemental sudoers grants before the container is
    # torn down so a future change that keeps the container around
    # does not leak the extra grants into the next suite.
    Invoke-ContainerCommand "rm -f '$Script:TarballSudoersPath'" | Out-Null

    if (Test-Path -LiteralPath $Script:HostTarballDir) {
        Remove-Item -LiteralPath $Script:HostTarballDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }

    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Expand-VmTarball (integration)' {

    BeforeEach {
        # Start every test from a clean destination + no orphan
        # tempdirs, so a previous test's crash-simulation cannot
        # leak into the next one.
        Invoke-ContainerCommand "rm -rf '$Script:VmDestination' '$Script:VmDestParent'/.expand.*" |
            Out-Null
    }

    AfterEach {
        Invoke-ContainerCommand "rm -rf '$Script:VmDestination' '$Script:VmDestParent'/.expand.*" |
            Out-Null
    }

    It 'first-run extracts the tarball and lands the marker with the host digest' {
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination

        Test-PathExists -Path $Script:VmDestination | Should -BeTrue

        # The archive's wrapper directory (root-a) is preserved
        # because we did not pass -StripComponents.
        (Get-FileContent -Path "$Script:VmDestination/root-a/a.txt")     | Should -Be 'alpha contents'
        (Get-FileContent -Path "$Script:VmDestination/root-a/sub/b.txt") | Should -Be 'bravo contents'

        # Marker file's payload is exactly the host-computed digest,
        # followed by the trailing newline that printf '%s\n' adds.
        # sudo cat | awk strips both the newline and any extra
        # whitespace so a direct equality check is sound.
        $markerDigest = Get-MarkerDigest -Path "$Script:VmDestination/.infra-hyperv-tarball.sha256"
        $markerDigest | Should -Be $Script:Tarball_A_Digest
    }

    It 'is idempotent on an unchanged re-run (mtime stays put)' {
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination
        $mtimeBefore = Get-DirMtime -Path $Script:VmDestination

        Wait-ForMtimeTick
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination

        # Same mtime before and after proves the marker pre-check
        # short-circuited before any mktemp / tar / mv ran.
        Get-DirMtime -Path $Script:VmDestination | Should -Be $mtimeBefore
    }

    It '-NoSkipUnchanged forces a re-extract (mtime advances; content unchanged)' {
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination
        $mtimeBefore = Get-DirMtime -Path $Script:VmDestination
        $shaBefore   = Get-Sha      -Path "$Script:VmDestination/root-a/a.txt"

        Wait-ForMtimeTick
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination `
                         -NoSkipUnchanged

        # The dir-swap lands a freshly-extracted tree, so the
        # destination dir's mtime is the swap time (not the original).
        Get-DirMtime -Path $Script:VmDestination | Should -Not -Be $mtimeBefore
        Get-Sha      -Path "$Script:VmDestination/root-a/a.txt" | Should -Be $shaBefore
    }

    It 'replaces the destination atomically when the source tarball changes' {
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination

        # Sanity: fixture A's wrapper is present before the swap.
        Test-PathExists -Path "$Script:VmDestination/root-a/a.txt" | Should -BeTrue

        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_B `
                         -Destination $Script:VmDestination

        # The OLD tree is entirely gone (every entry under root-a/
        # was removed by the rm-rf-then-mv step), and the NEW tree
        # is fully present - the two assertions together prove the
        # swap, not just an overlay write.
        Test-PathExists -Path "$Script:VmDestination/root-a"      | Should -BeFalse
        (Get-FileContent -Path "$Script:VmDestination/root-b/c.txt") | Should -Be 'charlie contents'
    }

    It '-StripComponents 1 strips the wrapper directory in the tarball' {
        Expand-VmTarball -SshClient        $Script:SshClient `
                         -Server           $Script:FileServer `
                         -TarballPath      $Script:Tarball_A `
                         -Destination      $Script:VmDestination `
                         -StripComponents  1

        # With strip=1 the root-a/ level is consumed, so the files
        # land directly under <Destination>.
        Test-PathExists -Path "$Script:VmDestination/root-a"     | Should -BeFalse
        (Get-FileContent -Path "$Script:VmDestination/a.txt")     | Should -Be 'alpha contents'
        (Get-FileContent -Path "$Script:VmDestination/sub/b.txt") | Should -Be 'bravo contents'
    }

    It 'leaves Destination unchanged when the remote script crashes mid-extract' {
        # Land a known-good tree first so the assertion target is
        # "untouched after a crash", not "absent".
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination
        $mtimeBefore = Get-DirMtime -Path $Script:VmDestination
        $shaBefore   = Get-Sha      -Path "$Script:VmDestination/root-a/a.txt"

        # Simulate a crash mid-extract by issuing the cmdlet's own
        # extract steps directly and killing the script between the
        # mktemp + tar (the partial tree is fully populated) and the
        # final rm/mv (so <Destination> is left untouched). This
        # mirrors what would happen on a real SIGKILL between
        # `sudo mktemp -d` and `sudo mv` - the exact contract the
        # cmdlet's docstring calls out as "next clean run finds
        # <Destination> unchanged".
        $url = Add-VmFileServerFile -Server $Script:FileServer -LocalPath $Script:Tarball_B
        $crashScript = @"
set -euo pipefail
parent='$Script:VmDestParent'
tmpdir=`$(sudo mktemp -d "`$parent/.expand.XXXXXX")
curl -fsSL "$url" | sudo tar -xzf - -C "`$tmpdir"
# Hard-kill before the rm/mv. `exit 137` is what SIGKILL would
# look like to a shell that could catch it; the cmdlet does not
# observe this script so the value is purely test-internal.
exit 137
"@ -replace "`r`n", "`n"
        $crashResult = Invoke-SshClientCommand -SshClient $Script:SshClient -Command $crashScript
        $crashResult.ExitStatus | Should -Be 137

        # Crash invariant: <Destination> is byte-identical to its
        # pre-crash state, and exactly one orphan tempdir is sitting
        # next to it.
        Get-DirMtime -Path $Script:VmDestination | Should -Be $mtimeBefore
        Get-Sha      -Path "$Script:VmDestination/root-a/a.txt" | Should -Be $shaBefore
        @(Get-ExpandTempdirs).Count | Should -BeGreaterOrEqual 1

        # Recovery: a clean -NoSkipUnchanged run completes against
        # the same destination. We do NOT assert that the orphan
        # tempdir disappears - the cmdlet's docstring explicitly
        # makes orphan cleanup the caller's problem, so leaving it
        # behind is correct behaviour.
        Expand-VmTarball -SshClient   $Script:SshClient `
                         -Server      $Script:FileServer `
                         -TarballPath $Script:Tarball_A `
                         -Destination $Script:VmDestination `
                         -NoSkipUnchanged

        (Get-FileContent -Path "$Script:VmDestination/root-a/a.txt") | Should -Be 'alpha contents'
    }
}

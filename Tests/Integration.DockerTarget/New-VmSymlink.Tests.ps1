# Integration tests for New-VmSymlink against a real SSH target.
# See Initialize-DockerTargetEnvironment.ps1 for environment details.
#
# Unit tests already pin the emitted script shape. This file proves
# the conflict guards behave under a real shell, that ownership lands
# as root:root after `sudo ln -s`, and that an identical re-run truly
# does not touch the link (its lstat mtime stays put).

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    # /usr/local/bin/ is a normal symlink target site on Ubuntu (PATH
    # already includes it). It is owned by root, so creating links here
    # exercises the sudo path the cmdlet relies on.
    $Script:LinkDir   = '/usr/local/bin'
    $Script:LinkName  = 'infra-integration-test-link'
    $Script:LinkPath  = "$Script:LinkDir/$Script:LinkName"
    $Script:Target1   = '/usr/bin/true'
    $Script:Target2   = '/usr/bin/false'

    function Get-LinkMeta {
        # `stat` without -L is lstat: returns the symlink's own metadata,
        # not the target's. %U:%G is owner/group, %Y is mtime epoch.
        return Invoke-SshQuery "stat -c '%U:%G %Y' '$Script:LinkPath'"
    }

    function Get-LinkTarget {
        return Invoke-SshQuery "readlink '$Script:LinkPath'"
    }

    function Test-LinkExists {
        # `test -L` is lstat-based; this is true for a symlink even if
        # the target is missing.
        $rc = Invoke-SshQuery "test -L '$Script:LinkPath' && echo yes || echo no"
        return ($rc -eq 'yes')
    }

    # See Set-VmEnvironmentVariables.Tests.ps1 for the rationale: 1.1s
    # comfortably distinguishes a write-induced mtime tick from a fast
    # replay no-op on overlayfs.
    function Wait-ForMtimeTick { Start-Sleep -Milliseconds 1100 }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'New-VmSymlink (integration)' {

    BeforeEach {
        # Wipe any prior fixture so each It block starts from a clean
        # slate. `rm -f` does not fail when the path is missing.
        Invoke-ContainerCommand "rm -f '$Script:LinkPath'" | Out-Null
    }

    AfterEach {
        Invoke-ContainerCommand "rm -f '$Script:LinkPath'" | Out-Null
    }

    It 'creates a symlink owned by root:root pointing at the requested target' {
        New-VmSymlink -SshClient $Script:SshClient `
                      -Path     $Script:LinkPath `
                      -Target   $Script:Target1

        Test-LinkExists  | Should -BeTrue
        Get-LinkTarget   | Should -Be $Script:Target1

        # lstat owner of the symlink itself is root:root because the
        # link was created via `sudo ln -s`. Bind to a local first;
        # `(Get-LinkMeta -split ' ')` binds -split to the function call,
        # not to its return value.
        $meta = Get-LinkMeta
        ($meta -split ' ')[0] | Should -Be 'root:root'

        # `readlink -f` follows the chain to the canonical real file -
        # proves the link resolves under a real shell (not just that
        # the bytes after `->` match).
        $resolved = Invoke-SshQuery "readlink -f '$Script:LinkPath'"
        $resolved | Should -Be $Script:Target1
    }

    It 'is idempotent on an unchanged re-run (link mtime stays put)' {
        New-VmSymlink -SshClient $Script:SshClient `
                      -Path     $Script:LinkPath `
                      -Target   $Script:Target1
        $metaBefore = Get-LinkMeta

        Wait-ForMtimeTick
        New-VmSymlink -SshClient $Script:SshClient `
                      -Path     $Script:LinkPath `
                      -Target   $Script:Target1

        # If the cmdlet had re-run `sudo ln -s`, the lstat mtime would
        # have advanced. Same value before and after proves the
        # readlink-equality short-circuit fired on the VM.
        Get-LinkMeta | Should -Be $metaBefore
    }

    It 'throws when the link already points at a different target and leaves the original alone' {
        New-VmSymlink -SshClient $Script:SshClient `
                      -Path     $Script:LinkPath `
                      -Target   $Script:Target1
        $targetBefore = Get-LinkTarget

        { New-VmSymlink -SshClient $Script:SshClient `
                        -Path     $Script:LinkPath `
                        -Target   $Script:Target2 } |
            Should -Throw -ExpectedMessage '*conflict*'

        Get-LinkTarget | Should -Be $targetBefore
    }

    It 'throws when <Path> exists as a regular file and leaves the file byte-identical' {
        # Pre-create a regular file at the link path. docker exec runs as
        # root in the container, which is the simplest way to write into
        # /usr/local/bin without touching the deploy-user sudoers.
        $content = 'pre-existing regular file content'
        Invoke-ContainerCommand "printf '%s' '$content' > '$Script:LinkPath'" | Out-Null
        $shaBefore = Invoke-SshQuery "sha256sum '$Script:LinkPath' | awk '{print `$1}'"

        { New-VmSymlink -SshClient $Script:SshClient `
                        -Path     $Script:LinkPath `
                        -Target   $Script:Target1 } |
            Should -Throw -ExpectedMessage '*conflict*regular file*'

        # File must still be a regular file (NOT replaced by a symlink)
        # and its bytes must be identical - the cmdlet's "never silently
        # clobber" contract.
        $isFile = Invoke-SshQuery "test -f '$Script:LinkPath' && ! test -L '$Script:LinkPath' && echo yes || echo no"
        $isFile | Should -Be 'yes'
        $shaAfter = Invoke-SshQuery "sha256sum '$Script:LinkPath' | awk '{print `$1}'"
        $shaAfter | Should -Be $shaBefore
    }
}

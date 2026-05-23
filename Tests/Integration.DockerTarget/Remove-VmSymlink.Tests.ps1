# Integration tests for Remove-VmSymlink against a real SSH target.
# See Initialize-DockerTargetEnvironment.ps1 for environment details.
#
# Unit tests already pin the emitted script shape. This file proves
# the wrong-type guard refuses to delete non-symlinks under a real
# shell, and that the absent-path branch is truly a no-op.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    $Script:LinkDir   = '/usr/local/bin'
    $Script:LinkName  = 'infra-integration-test-link'
    $Script:LinkPath  = "$Script:LinkDir/$Script:LinkName"
    $Script:Target1   = '/usr/bin/true'

    function Test-LinkExists {
        $rc = Invoke-SshQuery "test -L '$Script:LinkPath' && echo yes || echo no"
        return ($rc -eq 'yes')
    }

    function Test-AnyExists {
        # -e follows symlinks; -L only matches symlinks. Combining them
        # answers "is anything at this path (symlink or otherwise)".
        $rc = Invoke-SshQuery "(test -e '$Script:LinkPath' || test -L '$Script:LinkPath') && echo yes || echo no"
        return ($rc -eq 'yes')
    }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Remove-VmSymlink (integration)' {

    BeforeEach {
        Invoke-ContainerCommand "rm -f '$Script:LinkPath'" | Out-Null
    }

    AfterEach {
        Invoke-ContainerCommand "rm -f '$Script:LinkPath'" | Out-Null
    }

    It 'removes an existing symlink' {
        New-VmSymlink -SshClient $Script:SshClient `
                      -Path     $Script:LinkPath `
                      -Target   $Script:Target1
        Test-LinkExists | Should -BeTrue

        Remove-VmSymlink -SshClient $Script:SshClient -Path $Script:LinkPath

        Test-AnyExists | Should -BeFalse
    }

    It 'is a no-op when the path does not exist' {
        Test-AnyExists | Should -BeFalse

        # No throw on absent: the cmdlet treats "already gone" as
        # success (idempotent uninstall contract).
        { Remove-VmSymlink -SshClient $Script:SshClient -Path $Script:LinkPath } |
            Should -Not -Throw

        Test-AnyExists | Should -BeFalse
    }

    It 'throws when <Path> is a regular file and leaves the file byte-identical' {
        $content = 'pre-existing regular file content'
        Invoke-ContainerCommand "printf '%s' '$content' > '$Script:LinkPath'" | Out-Null
        $shaBefore = Invoke-SshQuery "sha256sum '$Script:LinkPath' | awk '{print `$1}'"

        { Remove-VmSymlink -SshClient $Script:SshClient -Path $Script:LinkPath } |
            Should -Throw -ExpectedMessage '*conflict*regular file*'

        # The file must still be there and byte-identical - the cmdlet's
        # refuse-to-delete-non-symlink contract.
        $isFile = Invoke-SshQuery "test -f '$Script:LinkPath' && ! test -L '$Script:LinkPath' && echo yes || echo no"
        $isFile | Should -Be 'yes'
        $shaAfter = Invoke-SshQuery "sha256sum '$Script:LinkPath' | awk '{print `$1}'"
        $shaAfter | Should -Be $shaBefore
    }
}

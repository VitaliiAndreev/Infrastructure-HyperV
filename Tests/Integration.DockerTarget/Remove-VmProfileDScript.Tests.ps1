# Integration tests for Remove-VmProfileDScript against a real SSH
# target. See Initialize-DockerTargetEnvironment.ps1 for environment
# details.
#
# Unit tests already pin the emitted script shape. This file proves the
# remove path actually deletes the file under a real shell, and that the
# absent-target branch is a true no-op (no throw, no side effect).

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    $Script:ScriptName = 'infra-integration-test'
    $Script:ScriptPath = "/etc/profile.d/$Script:ScriptName.sh"

    function Test-FileExists {
        $rc = Invoke-SshQuery "test -e '$Script:ScriptPath' && echo yes || echo no"
        return ($rc -eq 'yes')
    }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Remove-VmProfileDScript (integration)' {

    BeforeEach {
        Invoke-ContainerCommand "rm -f '$Script:ScriptPath'" | Out-Null
    }

    AfterEach {
        Invoke-ContainerCommand "rm -f '$Script:ScriptPath'" | Out-Null
    }

    It 'removes an existing profile.d script' {
        # Stage via the install cmdlet rather than docker exec so the
        # tear-down path is exercised against state shaped exactly the
        # way production will leave it (root:root 0644 with the
        # trailing-newline normalisation applied).
        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   "export FOO=1`n"
        Test-FileExists | Should -BeTrue

        Remove-VmProfileDScript -SshClient $Script:SshClient `
                                -Name      $Script:ScriptName

        Test-FileExists | Should -BeFalse
    }

    It 'is a no-op when the script is already absent' {
        Test-FileExists | Should -BeFalse

        # Idempotent uninstall contract: "already gone" is success,
        # never an exception. Matches Remove-VmSymlink's behaviour.
        { Remove-VmProfileDScript -SshClient $Script:SshClient `
                                  -Name      $Script:ScriptName } |
            Should -Not -Throw

        Test-FileExists | Should -BeFalse
    }
}

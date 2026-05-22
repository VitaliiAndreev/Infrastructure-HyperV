BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so command resolution
    # succeeds without loading the whole module. The tests capture or
    # re-mock per case.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Symlinks\Remove-VmSymlink.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
}

Describe 'Remove-VmSymlink' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'happy path' {

        It 'emits set -e at the top of the script' {
            Remove-VmSymlink -SshClient $script:FakeSshClient `
                             -Path '/usr/local/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '(?m)^set -e\b'
            }
        }

        It 'contains the existence check that short-circuits with exit 0' {
            Remove-VmSymlink -SshClient $script:FakeSshClient `
                             -Path '/usr/local/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '\[ ! -e "\$path" \] && \[ ! -L "\$path" \]' -and
                $Command -match '(?m)^\s*exit 0\b'
            }
        }

        It 'contains the symlink-type guard that exits 65 on non-symlink' {
            Remove-VmSymlink -SshClient $script:FakeSshClient `
                             -Path '/usr/local/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '\[ ! -L "\$path" \]' -and
                $Command -match 'exit 65'
            }
        }

        It 'invokes sudo rm against the path variable' {
            Remove-VmSymlink -SshClient $script:FakeSshClient `
                             -Path '/usr/local/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo rm "\$path"'
            }
        }

        It 'embeds Path as a single-quoted bash assignment' {
            Remove-VmSymlink -SshClient $script:FakeSshClient `
                             -Path '/usr/local/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "path='/usr/local/bin/foo'"
            }
        }
    }

    Context 'remote error handling' {

        It 'returns silently on ExitStatus 0' {
            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path '/usr/local/bin/foo' } | Should -Not -Throw
        }

        It 'throws naming the path on ExitStatus 65 (conflict)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 65
                    Output     = ''
                    Error      = 'exists as regular file'
                }
            }

            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path '/usr/local/bin/foo' } |
                Should -Throw -ExpectedMessage '*/usr/local/bin/foo*'
        }

        It 'includes the observed-type stderr in the conflict exception' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 65
                    Output     = ''
                    Error      = 'exists as directory'
                }
            }

            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path '/usr/local/bin/foo' } |
                Should -Throw -ExpectedMessage '*exists as directory*'
        }

        It 'throws with stderr on non-zero / non-65 ExitStatus' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = 'rm: permission denied'
                }
            }

            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path '/usr/local/bin/foo' } |
                Should -Throw -ExpectedMessage '*permission denied*'
        }
    }

    Context 'host-side validation' {

        It 'throws before SSH on an empty Path' {
            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path '' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a relative Path' {
            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path 'usr/local/bin/foo' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing ..' {
            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path '/usr/local/../etc/passwd' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing NUL' {
            $bad = "/usr/local/bin/foo" + [char]0 + "bar"
            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path $bad } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It "throws before SSH on a Path containing a single quote" {
            { Remove-VmSymlink -SshClient $script:FakeSshClient `
                               -Path "/usr/local/bin/foo'bar" } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'line-ending normalisation' {

        It 'emits no CR bytes in the command' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Remove-VmSymlink -SshClient $script:FakeSshClient `
                             -Path '/usr/local/bin/foo'

            $script:captured | Should -Not -Match "`r"
        }
    }
}

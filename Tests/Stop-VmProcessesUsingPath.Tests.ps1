BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so command
    # resolution succeeds without loading the whole module. The tests
    # re-mock per case.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Processes\Stop-VmProcessesUsingPath.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
}

Describe 'Stop-VmProcessesUsingPath' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{
                ExitStatus = 0
                Output     = "TERMINATED= KILLED= STILL_ALIVE=`n"
                Error      = ''
            }
        }
    }

    Context 'emitted script shape' {

        It 'opens with set -euo pipefail' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '(?m)^set -euo pipefail\b'
            }
        }

        It 'embeds Path as a single-quoted bash assignment' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "path='/opt/foo'"
            }
        }

        It 'contains all three scanner branches in lsof -> fuser -> proc-walk order' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $lsofIdx  = $Command.IndexOf('lsof')
                $fuserIdx = $Command.IndexOf('fuser')
                $procIdx  = $Command.IndexOf('/proc/[0-9]')
                ($lsofIdx -ge 0) -and ($fuserIdx -gt $lsofIdx) -and ($procIdx -gt $fuserIdx)
            }
        }

        It 'sends sudo kill -TERM (no SIGKILL in this step)' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                ($Command -match 'sudo kill -TERM') -and
                ($Command -notmatch 'kill -KILL') -and
                ($Command -notmatch 'kill -9')
            }
        }

        It 'hard-codes KILLED= as empty in the report line (Step 8 will lift)' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'TERMINATED=\$terminated KILLED= STILL_ALIVE=\$still_alive'
            }
        }

        It 'includes the poll loop when GraceSeconds > 0' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                ($Command -match 'while \[ "\$elapsed" -lt 30 \]') -and
                ($Command -match 'sleep 0\.5')
            }
        }

        It 'omits the poll loop entirely when GraceSeconds = 0' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 0 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                ($Command -notmatch 'while \[') -and
                ($Command -notmatch 'sleep 0\.5')
            }
        }

        It 'exits 64 when any survivors remain' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'exit 64'
            }
        }
    }

    Context 'result parsing' {

        It 'returns three empty arrays when no processes hold the path' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "TERMINATED= KILLED= STILL_ALIVE=`n"
                    Error      = ''
                }
            }

            $r = Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3

            $r.TerminatedPids.Count | Should -Be 0
            $r.KilledPids.Count     | Should -Be 0
            $r.StillAlive.Count     | Should -Be 0
        }

        It 'parses TerminatedPids when all PIDs exit within grace' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "TERMINATED=101 102 KILLED= STILL_ALIVE=`n"
                    Error      = ''
                }
            }

            $r = Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3

            $r.TerminatedPids | Should -Be @(101, 102)
            $r.KilledPids.Count | Should -Be 0
            $r.StillAlive.Count | Should -Be 0
        }

        It 'throws naming survivors on ExitStatus 64' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 64
                    Output     = "TERMINATED=101 KILLED= STILL_ALIVE=202`n"
                    Error      = ''
                }
            }

            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 } |
                Should -Throw -ExpectedMessage '*202*'
        }

        It 'KilledPids is always empty in this step even with ExitStatus 0' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "TERMINATED=101 KILLED= STILL_ALIVE=`n"
                    Error      = ''
                }
            }

            $r = Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3

            $r.KilledPids.Count | Should -Be 0
        }

        It 'throws with stderr context on a missing result line' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = 'bash: lsof: command not found'
                }
            }

            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 } |
                Should -Throw -ExpectedMessage '*no result line*'
        }
    }

    Context 'host-side validation: malformed paths' {

        It 'throws before SSH on an empty Path' {
            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '' -GraceSeconds 3 } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a relative Path' {
            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path 'opt/foo' -GraceSeconds 3 } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing ..' {
            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/../etc' -GraceSeconds 3 } |
                Should -Throw -ExpectedMessage '*..*'
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing NUL' {
            $bad = '/opt/foo' + [char]0 + 'bar'
            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path $bad -GraceSeconds 3 } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It "throws before SSH on a Path containing a single quote" {
            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path "/opt/foo'bar" -GraceSeconds 3 } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on negative GraceSeconds' {
            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds -1 } |
                Should -Throw -ExpectedMessage '*non-negative*'
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'line-ending normalisation' {

        It 'emits no CR bytes in the command' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "TERMINATED= KILLED= STILL_ALIVE=`n"
                    Error      = ''
                }
            }

            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            $script:captured | Should -Not -Match "`r"
        }
    }
}

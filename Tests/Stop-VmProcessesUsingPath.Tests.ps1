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

        It 'sends sudo kill -TERM before any SIGKILL' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $termIdx = $Command.IndexOf('sudo kill -TERM')
                $killIdx = $Command.IndexOf('sudo kill -KILL')
                ($termIdx -ge 0) -and ($killIdx -gt $termIdx)
            }
        }

        It 'reports KILLED from the killed shell variable' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'TERMINATED=\$terminated KILLED=\$killed STILL_ALIVE=\$still_alive'
            }
        }

        It 'escalates only the SIGTERM survivors via SIGKILL' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'echo "\$sigterm_survivors" \| xargs -r sudo kill -KILL'
            }
        }

        It 'polls kill -0 for up to 5 seconds in the SIGKILL reap window' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                # 50 tenths = 5 seconds; loop body sleeps 0.5s and bumps by 5
                ($Command -match 'while \[ "\$kelapsed" -lt 50 \]') -and
                ($Command -match 'kelapsed=\$\(\(kelapsed \+ 5\)\)')
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

        It 'omits the SIGTERM grace poll when GraceSeconds = 0 (SIGKILL reap poll remains)' {
            Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 0 | Out-Null

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                # Grace poll references $elapsed; reap poll references $kelapsed.
                # Only the latter should be present.
                ($Command -notmatch '\$elapsed') -and
                ($Command -match '\$kelapsed')
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

        It 'parses KilledPids when SIGTERM survivors are reaped by SIGKILL' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "TERMINATED=101 KILLED=202 203 STILL_ALIVE=`n"
                    Error      = ''
                }
            }

            $r = Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3

            $r.TerminatedPids   | Should -Be @(101)
            $r.KilledPids       | Should -Be @(202, 203)
            $r.StillAlive.Count | Should -Be 0
        }

        It 'throws when survivors persist through SIGKILL (D state)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 64
                    Output     = "TERMINATED=101 KILLED=202 STILL_ALIVE=303`n"
                    Error      = ''
                }
            }

            { Stop-VmProcessesUsingPath -SshClient $script:FakeSshClient `
                -Path '/opt/foo' -GraceSeconds 3 } |
                Should -Throw -ExpectedMessage '*303*'
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

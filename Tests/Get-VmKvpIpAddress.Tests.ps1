BeforeAll {
    # Hyper-V cmdlets are unavailable outside a Hyper-V host. Stub
    # global no-ops here so Mock can replace them in each It; the
    # real loop body runs against the mocks, not Hyper-V.
    function Get-VM               { param($Name)   }
    function Get-VMNetworkAdapter { param($VMName) }

    # Assert-HyperVModuleLoaded is the private guard the helper calls
    # before touching Get-VM. Stub it so the file under test loads
    # without dot-sourcing the real Private/Power/* tree.
    function Assert-HyperVModuleLoaded { }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Power\Get-VmKvpIpAddress.ps1"
}

Describe 'Get-VmKvpIpAddress' {

    Context 'happy path' {
        It 'returns the discovered IPv4 from the first matching adapter' {
            Mock Get-VM               { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter {
                @([PSCustomObject]@{
                    SwitchName  = 'External'
                    IPAddresses = @('192.168.1.42', 'fe80::1234')
                })
            }

            Get-VmKvpIpAddress -VmName 'vm-01' | Should -Be '192.168.1.42'
        }

        It 'filters out IPv6 link-local addresses' {
            # KVP publishes both IPv4 and IPv6 the moment the link is up;
            # only the IPv4 lease is useful for downstream SSH probes.
            Mock Get-VM               { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter {
                @([PSCustomObject]@{
                    SwitchName  = 'External'
                    IPAddresses = @('fe80::abcd', '2001:db8::1', '10.0.0.5')
                })
            }

            Get-VmKvpIpAddress -VmName 'vm-01' | Should -Be '10.0.0.5'
        }
    }

    Context '-SwitchName discrimination' {
        # Router VMs have two NICs: one on the external switch (the
        # one we want for KVP IP discovery) and one on the private
        # switch (which only carries link-locals from its peers). The
        # filter must pick the right adapter or downstream consumers
        # try to SSH into the private subnet the host cannot reach.

        It 'returns the IP from the adapter whose SwitchName matches' {
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter {
                @(
                    [PSCustomObject]@{
                        SwitchName  = 'PrivateSwitch'
                        IPAddresses = @('10.99.0.1')
                    },
                    [PSCustomObject]@{
                        SwitchName  = 'ExternalSwitch-Shared'
                        IPAddresses = @('192.168.1.211')
                    }
                )
            }

            Get-VmKvpIpAddress -VmName 'router' `
                               -SwitchName 'ExternalSwitch-Shared' |
                Should -Be '192.168.1.211'
        }

        It 'omitting -SwitchName picks the first adapter regardless of switch' {
            # Single-NIC workloads do not need to discriminate; the
            # absence of -SwitchName is the green flag the caller knows
            # only one adapter exists.
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter {
                @([PSCustomObject]@{
                    SwitchName  = 'AnySwitch'
                    IPAddresses = @('10.0.0.50')
                })
            }

            Get-VmKvpIpAddress -VmName 'vm-01' | Should -Be '10.0.0.50'
        }
    }

    Context 'guards' {
        It 'throws immediately when the VM is not Running' {
            # KVP only publishes data for a Running VM; without this
            # guard a stopped VM would loop silently to the deadline.
            Mock Get-VM               { [PSCustomObject]@{ State = 'Off' } }
            Mock Get-VMNetworkAdapter { @() }

            { Get-VmKvpIpAddress -VmName 'vm-01' } |
                Should -Throw -ExpectedMessage "*is not Running*Off*"
        }

        It 'throws with a deadline message when KVP never publishes an IP' {
            # Negative TimeoutMinutes makes $deadline land in the past
            # at function entry, so the loop falls through to the
            # "did not report" throw without sleeping. Cleaner than
            # mocking Get-Date (which would also need to be stateful to
            # avoid an infinite loop).
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter { @() }

            { Get-VmKvpIpAddress -VmName 'vm-01' -TimeoutMinutes -1 } |
                Should -Throw -ExpectedMessage "*did not report an IPv4 address*"
        }

        It 'mentions the -SwitchName in the deadline error when supplied' {
            # Operator-actionable diagnostics: name the switch so the
            # operator knows which side of a multi-NIC VM to chase.
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter { @() }

            { Get-VmKvpIpAddress -VmName 'router' `
                                 -SwitchName 'ExternalSwitch-Shared' `
                                 -TimeoutMinutes -1 } |
                Should -Throw -ExpectedMessage "*ExternalSwitch-Shared*"
        }
    }

    Context '-OnPoll callback' {
        It 'invokes OnPoll once per "no IP yet" iteration' {
            # Provisioner uses this to paint progress dots; E2E stays
            # silent by omitting -OnPoll. Verify the helper actually
            # fires the callback so a UI regression surfaces here.
            $script:_kvpAdapterCallCount = 0
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }
            Mock Get-VMNetworkAdapter {
                $script:_kvpAdapterCallCount++
                if ($script:_kvpAdapterCallCount -lt 3) {
                    return @()
                }
                @([PSCustomObject]@{
                    SwitchName  = 'X'
                    IPAddresses = @('10.0.0.99')
                })
            }
            Mock Start-Sleep { }

            $script:_pollFires = 0
            Get-VmKvpIpAddress -VmName 'vm' -PollIntervalSeconds 0 -OnPoll {
                $script:_pollFires++
            } | Should -Be '10.0.0.99'

            # 2 no-IP iterations -> 2 OnPoll fires; the third iteration
            # finds the IP and exits without firing OnPoll.
            $script:_pollFires | Should -Be 2
        }
    }
}

<#
.SYNOPSIS
    Hyper-V VM utilities for infrastructure repos.

.DESCRIPTION
    Provides VM-facing functions extracted from Infrastructure.Common to
    keep each module cohesive and single-purpose. All functions in this
    module assume a Hyper-V VM on an internal switch that the host can
    reach over SSH or HTTP.

    Private helpers (Assert-SshNetLoaded, Get-VmSwitchHostIp,
    Start-VmFileServer, Stop-VmFileServer) are dot-sourced below but not
    exported.

    Each function lives in its own file under Public\ or Private\ and is
    dot-sourced below so diffs stay focused on a single function per commit.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Export-ModuleMember controls what is actually callable after Import-Module.
# It takes precedence over FunctionsToExport in the psd1 at runtime, so both
# must be kept in sync. FunctionsToExport serves a separate purpose: it is
# read by Get-Module -ListAvailable, Find-Module, and PSGallery for fast
# discovery without loading the module. The shared Module.Tests.ps1 in the
# run-unit-tests action enforces that every Public\*.ps1 file appears in both.
Export-ModuleMember -Function @(
    'Add-VmFileServerFile',
    'Invoke-SshClientCommand',
    'Invoke-WithVmFileServer',
    'New-VmSshClient'
)

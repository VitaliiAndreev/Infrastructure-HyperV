# Integration tests for Set-VmEnvironmentVariables against a real SSH
# target. See Initialize-DockerTargetEnvironment.ps1 for environment
# details.
#
# Unit tests already pin the script shape (markers, escape sequences,
# reconcile / write branches). This file proves the script's awk
# extraction, atomic mv, out-of-block preservation, skip-unchanged
# reconcile and per-blockName isolation actually behave end-to-end.
#
# Convention: arrangements that need root (resetting /etc/environment
# to a known baseline, injecting drift) run via Invoke-ContainerCommand
# so we never accidentally lean on extra sudo grants for test setup.
# The transport under test always runs via SSH as the deploy user.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    # Baseline /etc/environment. Mirrors Ubuntu's default single PATH
    # line - small enough to assert against, real enough that
    # out-of-block preservation has a victim to preserve.
    $Script:EnvPath        = '/etc/environment'
    $Script:BaselinePath   =
        'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
    $Script:BaselineFile   = "$Script:BaselinePath`n"
    $Script:BlockName      = 'integration-block'

    function Reset-VmEnvFile {
        # Write a known baseline as root, restoring owner / mode that
        # the transport relies on. Done via docker exec so the test
        # setup does not need extra sudoers grants.
        $script = @"
cat > $Script:EnvPath <<'__BASELINE__'
$Script:BaselinePath
__BASELINE__
chown root:root $Script:EnvPath
chmod 0644 $Script:EnvPath
"@ -replace "`r`n", "`n"
        Invoke-ContainerCommand $script | Out-Null
    }

    function Get-VmEnvFile {
        # /etc/environment is 0644 root:root so plain cat (no sudo)
        # is sufficient and avoids needing /usr/bin/cat in sudoers
        # solely for the verification side.
        return Invoke-SshQuery "cat $Script:EnvPath"
    }

    function Get-VmEnvFileMtime {
        return Invoke-SshQuery "stat -c '%y' $Script:EnvPath"
    }

    function Get-VmEnvFileMeta {
        return Invoke-SshQuery "stat -c '%U:%G %a' $Script:EnvPath"
    }

    # Coarser filesystem mtime resolutions (overlayfs on older
    # kernels) cap mtime at 1s; 1.1s comfortably distinguishes a
    # write-induced tick from a fast-replay no-op. Same rationale as
    # Copy-VmFiles.SkipUnchanged.Tests.ps1.
    function Wait-ForMtimeTick { Start-Sleep -Milliseconds 1100 }

    function Invoke-SetEnv {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()]
            [object[]] $Entries,
            [string]   $BlockName = $Script:BlockName,
            [switch]   $NoSkipUnchanged
        )
        $params = @{
            SshClient = $Script:SshClient
            Entries   = $Entries
            BlockName = $BlockName
        }
        if ($NoSkipUnchanged) { $params['NoSkipUnchanged'] = $true }
        Set-VmEnvironmentVariables @params
    }

    function New-EnvEntry {
        param([string] $Name, [string] $Value)
        return [PSCustomObject]@{ name = $Name; value = $Value }
    }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Set-VmEnvironmentVariables (integration)' {

    BeforeEach {
        Reset-VmEnvFile
    }

    It 'creates the managed block on first run and preserves out-of-block lines' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo'),
            (New-EnvEntry 'BAR_OPTS' '-Xmx512m')
        )

        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape($Script:BaselinePath))
        $content | Should -Match ([regex]::Escape("# BEGIN $Script:BlockName"))
        $content | Should -Match ([regex]::Escape("# END $Script:BlockName"))
        $content | Should -Match ([regex]::Escape('FOO_HOME="/opt/foo"'))
        $content | Should -Match ([regex]::Escape('BAR_OPTS="-Xmx512m"'))

        # FOO_HOME precedes BAR_OPTS - the transport preserves the
        # caller's order so diffs across runs stay minimal.
        $fooIdx = $content.IndexOf('FOO_HOME=')
        $barIdx = $content.IndexOf('BAR_OPTS=')
        $fooIdx | Should -BeLessThan $barIdx

        Get-VmEnvFileMeta | Should -Be 'root:root 644'
    }

    It 'is idempotent on an unchanged re-run (mtime stays put)' {
        $entries = @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo'),
            (New-EnvEntry 'BAR_OPTS' '-Xmx512m')
        )
        Invoke-SetEnv -Entries $entries
        $before     = Get-VmEnvFile
        $mtimeBefore = Get-VmEnvFileMtime

        Wait-ForMtimeTick
        Invoke-SetEnv -Entries $entries

        Get-VmEnvFileMtime | Should -Be $mtimeBefore
        Get-VmEnvFile      | Should -Be $before
    }

    It '-NoSkipUnchanged forces a write while keeping content byte-identical' {
        $entries = @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo'),
            (New-EnvEntry 'BAR_OPTS' '-Xmx512m')
        )
        Invoke-SetEnv -Entries $entries
        $before     = Get-VmEnvFile
        $mtimeBefore = Get-VmEnvFileMtime

        Wait-ForMtimeTick
        Invoke-SetEnv -Entries $entries -NoSkipUnchanged

        Get-VmEnvFileMtime | Should -Not -Be $mtimeBefore
        Get-VmEnvFile      | Should -Be $before
    }

    It 'adds a key on a re-run with one extra entry' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo'),
            (New-EnvEntry 'BAR_OPTS' '-Xmx512m')
        )

        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo'),
            (New-EnvEntry 'BAR_OPTS' '-Xmx512m'),
            (New-EnvEntry 'BAZ_DIR'  '/var/cache/baz')
        )

        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape('FOO_HOME="/opt/foo"'))
        $content | Should -Match ([regex]::Escape('BAR_OPTS="-Xmx512m"'))
        $content | Should -Match ([regex]::Escape('BAZ_DIR="/var/cache/baz"'))
        $content | Should -Match ([regex]::Escape($Script:BaselinePath))

        # Order assertions: FOO < BAR < BAZ.
        ($content.IndexOf('FOO_HOME=')) | Should -BeLessThan ($content.IndexOf('BAR_OPTS='))
        ($content.IndexOf('BAR_OPTS=')) | Should -BeLessThan ($content.IndexOf('BAZ_DIR='))
    }

    It 'removes a key when its entry is dropped from the next run' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo'),
            (New-EnvEntry 'BAR_OPTS' '-Xmx512m'),
            (New-EnvEntry 'BAZ_DIR'  '/var/cache/baz')
        )

        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )

        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape('FOO_HOME="/opt/foo"'))
        # BAR_OPTS / BAZ_DIR must be gone entirely - not commented
        # out, not lurking outside the block.
        $content | Should -Not -Match 'BAR_OPTS'
        $content | Should -Not -Match 'BAZ_DIR'
        $content | Should -Match ([regex]::Escape($Script:BaselinePath))
    }

    It 'preserves drift that appears OUTSIDE the managed block' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )

        # Append an unrelated line after the END marker. docker exec
        # avoids needing sudo tee -a in the deploy-user sudoers.
        Invoke-ContainerCommand `
            "printf '%s\n' 'LANG=`"en_US.UTF-8`"' >> $Script:EnvPath" | Out-Null

        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )

        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape('LANG="en_US.UTF-8"'))
        $content | Should -Match ([regex]::Escape('FOO_HOME="/opt/foo"'))
        $content | Should -Match ([regex]::Escape($Script:BaselinePath))
    }

    It 'reverts drift that appears INSIDE the managed block' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )

        # Drift one line inside the managed block. sed -i preserves
        # surrounding lines; running it as root avoids any sudo grant
        # gymnastics on the deploy user.
        Invoke-ContainerCommand `
            "sed -i 's|FOO_HOME=`"/opt/foo`"|FOO_HOME=`"/tampered`"|' $Script:EnvPath" |
            Out-Null

        $tampered = Get-VmEnvFile
        $tampered | Should -Match ([regex]::Escape('FOO_HOME="/tampered"'))

        # Same entries, default skip-unchanged: reconcile must see a
        # content mismatch and re-write the block.
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )

        $content = Get-VmEnvFile
        $content | Should -Match    ([regex]::Escape('FOO_HOME="/opt/foo"'))
        $content | Should -Not -Match ([regex]::Escape('/tampered'))
    }

    It 'removes the entire managed block when called with an empty entries array' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )
        # Add an unrelated line before the removal so we also verify
        # out-of-block preservation across the strip path.
        Invoke-ContainerCommand `
            "printf '%s\n' 'LANG=`"en_US.UTF-8`"' >> $Script:EnvPath" | Out-Null

        Invoke-SetEnv -Entries @()

        $content = Get-VmEnvFile
        $content | Should -Not -Match ([regex]::Escape("# BEGIN $Script:BlockName"))
        $content | Should -Not -Match ([regex]::Escape("# END $Script:BlockName"))
        $content | Should -Not -Match 'FOO_HOME'
        $content | Should -Match ([regex]::Escape($Script:BaselinePath))
        $content | Should -Match ([regex]::Escape('LANG="en_US.UTF-8"'))
    }

    It 're-creates the managed block after a previous empty-entries removal' {
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'FOO_HOME' '/opt/foo')
        )
        Invoke-SetEnv -Entries @()
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'BAR_OPTS' '-Xmx256m')
        )

        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape("# BEGIN $Script:BlockName"))
        $content | Should -Match ([regex]::Escape("# END $Script:BlockName"))
        $content | Should -Match ([regex]::Escape('BAR_OPTS="-Xmx256m"'))
        $content | Should -Not -Match 'FOO_HOME'
    }

    It 'round-trips values containing quote, backslash and space' {
        $value = 'a"b\c d'
        Invoke-SetEnv -Entries @(
            (New-EnvEntry 'SPECIAL_VAL' $value)
        )

        # On-disk shape: backslash escaped first, then double-quote.
        # `a"b\c d` -> `a\"b\\c d` inside `"..."`.
        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape('SPECIAL_VAL="a\"b\\c d"'))

        # Round-trip via bash sourcing - mirrors how /etc/environment
        # is consumed at login. `set -a` exports anything sourced;
        # bash's parser handles the `\"` and `\\` escapes inside the
        # double-quoted literal so $SPECIAL_VAL ends up with the
        # original bytes.
        $sourced = Invoke-SshQuery `
            "bash -c 'set -a; . $Script:EnvPath; printf %s `"`$SPECIAL_VAL`"'"
        $sourced | Should -Be $value
    }

    It 'lets two block names coexist and isolates their lifecycle' {
        $blockA = 'integration-a'
        $blockB = 'integration-b'

        $entriesA = @(
            (New-EnvEntry 'A_ONE' 'alpha-1'),
            (New-EnvEntry 'A_TWO' 'alpha-2')
        )
        $entriesB = @(
            (New-EnvEntry 'B_ONE' 'beta-1'),
            (New-EnvEntry 'B_TWO' 'beta-2')
        )

        Invoke-SetEnv -BlockName $blockA -Entries $entriesA
        Invoke-SetEnv -BlockName $blockB -Entries $entriesB

        $content = Get-VmEnvFile
        $content | Should -Match ([regex]::Escape("# BEGIN $blockA"))
        $content | Should -Match ([regex]::Escape("# END $blockA"))
        $content | Should -Match ([regex]::Escape("# BEGIN $blockB"))
        $content | Should -Match ([regex]::Escape("# END $blockB"))
        $content | Should -Match ([regex]::Escape('A_ONE="alpha-1"'))
        $content | Should -Match ([regex]::Escape('B_ONE="beta-1"'))

        # B's keys must not appear inside A's block, and vice versa.
        # awk-extract block A and check it does not contain any B_ key.
        $insideA = Invoke-SshQuery (
            "awk -v b='# BEGIN $blockA' -v e='# END $blockA' " +
            "'`$0==b{f=1;next} `$0==e{f=0;next} f' $Script:EnvPath")
        $insideA | Should -Match 'A_ONE'
        $insideA | Should -Not -Match 'B_ONE'
        $insideA | Should -Not -Match 'B_TWO'

        $insideB = Invoke-SshQuery (
            "awk -v b='# BEGIN $blockB' -v e='# END $blockB' " +
            "'`$0==b{f=1;next} `$0==e{f=0;next} f' $Script:EnvPath")
        $insideB | Should -Match 'B_ONE'
        $insideB | Should -Not -Match 'A_ONE'
        $insideB | Should -Not -Match 'A_TWO'

        # Idempotent re-run of A leaves B's block byte-identical -
        # locks in "blocks are isolated, not just textually separate".
        $bBefore = Invoke-SshQuery (
            "awk -v b='# BEGIN $blockB' -v e='# END $blockB' " +
            "'`$0==b{p=1} p{print} `$0==e{p=0}' $Script:EnvPath")

        Invoke-SetEnv -BlockName $blockA -Entries $entriesA

        $bAfter = Invoke-SshQuery (
            "awk -v b='# BEGIN $blockB' -v e='# END $blockB' " +
            "'`$0==b{p=1} p{print} `$0==e{p=0}' $Script:EnvPath")
        $bAfter | Should -Be $bBefore

        # Removing A leaves B intact, byte-for-byte.
        Invoke-SetEnv -BlockName $blockA -Entries @()

        $content = Get-VmEnvFile
        $content | Should -Not -Match ([regex]::Escape("# BEGIN $blockA"))
        $content | Should -Not -Match ([regex]::Escape("# END $blockA"))
        $content | Should -Not -Match 'A_ONE'
        $content | Should -Not -Match 'A_TWO'
        $content | Should -Match ([regex]::Escape("# BEGIN $blockB"))
        $content | Should -Match ([regex]::Escape('B_ONE="beta-1"'))
        $content | Should -Match ([regex]::Escape('B_TWO="beta-2"'))
    }
}

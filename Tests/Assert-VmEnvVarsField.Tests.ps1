BeforeAll {
    # Pure function over the parsed VM object - no helpers to mock.
    # Dot-sourcing directly keeps the unit test boundary tight.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\EnvVars\Assert-VmEnvVarsField.ps1"

    # Build a VM whose envVars wrapper is built from a JSON snippet
    # for entries. The wrapper itself is always { blockName, entries }
    # so every existing per-entry test exercises the same outer shape
    # the v1 transport now requires.
    function New-VmWithEnvVarsJson(
        [string] $EntriesJson,
        [string] $BlockName = 'test-block'
    ) {
        $json = "{ `"vmName`": `"node-01`", `"envVars`": { `"blockName`": `"$BlockName`", `"entries`": $EntriesJson } }"
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutEnvVars {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }

    # Lets a test substitute its own raw envVars JSON expression
    # (object / string / null / array) for the wrapper-shape cases.
    function New-VmWithRawEnvVarsJson([string] $RawEnvVarsExpression) {
        $json = "{ `"vmName`": `"node-01`", `"envVars`": $RawEnvVarsExpression }"
        return ($json | ConvertFrom-Json)
    }

    # Build a VM whose envVars.entries[0].value contains the given
    # literal char. Done via the host-object route, not by
    # hand-crafting JSON with a NUL/CR/LF inside, because some of
    # those bytes break the JSON parser before the validator ever
    # sees them.
    function New-VmWithSingleValue([string] $Value) {
        return [pscustomobject]@{
            vmName  = 'node-01'
            envVars = [pscustomobject]@{
                blockName = 'test-block'
                entries   = @([pscustomobject]@{ name = 'FOO'; value = $Value })
            }
        }
    }
}

Describe 'Assert-VmEnvVarsField - presence and wrapper shape' {

    It 'returns silently when envVars is absent' {
        { Assert-VmEnvVarsField -Vm (New-VmWithoutEnvVars) } | Should -Not -Throw
    }

    It 'returns silently for an empty entries array (transport handles the remove-block semantic)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[]') } | Should -Not -Throw
    }

    It 'returns silently for a valid single entry' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "1" }]') } |
            Should -Not -Throw
    }

    It 'returns silently for multiple valid entries' {
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO_HOME", "value": "/opt/foo" },
    { "name": "BAR_OPTS", "value": "-Xmx512m" }
]
"@
        { Assert-VmEnvVarsField -Vm $vm } | Should -Not -Throw
    }

    It 'throws when envVars is a JSON array (old shape)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithRawEnvVarsJson '[{ "name": "X", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*envVars must be a JSON object with sub-fields 'blockName' and 'entries'*"
    }

    It 'throws when envVars is a string' {
        { Assert-VmEnvVarsField -Vm (New-VmWithRawEnvVarsJson '"FOO=1"') } |
            Should -Throw -ExpectedMessage "*must be a JSON object with sub-fields 'blockName' and 'entries'*"
    }

    It 'throws when envVars is JSON null (distinct from absent)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithRawEnvVarsJson 'null') } |
            Should -Throw -ExpectedMessage "*must be a JSON object with sub-fields 'blockName' and 'entries'*"
    }

    It 'throws when envVars is missing blockName' {
        { Assert-VmEnvVarsField -Vm (New-VmWithRawEnvVarsJson '{ "entries": [] }') } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'blockName'*"
    }

    It 'throws when envVars is missing entries' {
        { Assert-VmEnvVarsField -Vm (New-VmWithRawEnvVarsJson '{ "blockName": "x" }') } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'entries'*"
    }

    It 'throws on an unknown top-level sub-field naming the offending key' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": "x", "entries": [], "markerVersion": "v2" }'
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'markerVersion'*"
    }

    It 'throws when entries is not an array' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": "x", "entries": "FOO=1" }'
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*entries must be a JSON array*"
    }

    It 'names the VM in the error context' {
        { Assert-VmEnvVarsField -Vm (New-VmWithRawEnvVarsJson 'null') } |
            Should -Throw -ExpectedMessage "*VM 'node-01'*"
    }

    It "uses '(unknown)' when vmName is absent" {
        $vm = ('{ "envVars": null }' | ConvertFrom-Json)
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*VM '(unknown)'*"
    }
}

Describe 'Assert-VmEnvVarsField - blockName validation' {

    It 'rejects a blockName that is not a string' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": 5, "entries": [] }'
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*blockName must be a string*"
    }

    It 'rejects an empty blockName' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": "", "entries": [] }'
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*blockName must be a non-empty string*"
    }

    It 'rejects a blockName longer than 128 characters' {
        $long = ('a' * 129)
        $vm = New-VmWithRawEnvVarsJson ('{ "blockName": "' + $long + '", "entries": [] }')
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*length 129 exceeds the 128-char limit*"
    }

    It "rejects a blockName containing a single-quote" {
        $vm = New-VmWithRawEnvVarsJson "{ ""blockName"": ""bad'name"", ""entries"": [] }"
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*disallowed character*"
    }

    It 'rejects a blockName containing a newline (LF)' {
        $vm = [pscustomobject]@{
            vmName  = 'node-01'
            envVars = [pscustomobject]@{
                blockName = "bad`nname"
                entries   = @()
            }
        }
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*disallowed character*"
    }

    It 'rejects a blockName containing a carriage return (CR)' {
        $vm = [pscustomobject]@{
            vmName  = 'node-01'
            envVars = [pscustomobject]@{
                blockName = "bad`rname"
                entries   = @()
            }
        }
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*disallowed character*"
    }

    It 'rejects a blockName containing a NUL byte' {
        $vm = [pscustomobject]@{
            vmName  = 'node-01'
            envVars = [pscustomobject]@{
                blockName = "bad" + [char]0 + "name"
                entries   = @()
            }
        }
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*disallowed character*"
    }

    It 'rejects a blockName with a leading space' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": " leading", "entries": [] }'
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*must not start or end with whitespace*"
    }

    It 'rejects a blockName with a trailing space' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": "trailing ", "entries": [] }'
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*must not start or end with whitespace*"
    }

    It 'accepts the natural Infrastructure.HyperV envVars name with an internal space' {
        $vm = New-VmWithRawEnvVarsJson '{ "blockName": "Infrastructure.HyperV envVars", "entries": [] }'
        { Assert-VmEnvVarsField -Vm $vm } | Should -Not -Throw
    }
}

Describe 'Assert-VmEnvVarsField - per-entry shape' {

    It 'throws when an entry is JSON null' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[null]') } |
            Should -Throw -ExpectedMessage "*envVars.entries[[]0[]] must be a JSON object*"
    }

    It 'throws when an entry is a string' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '["FOO=1"]') } |
            Should -Throw -ExpectedMessage "*envVars.entries[[]0[]] must be a JSON object*"
    }

    It 'reports the offending entry index (off-by-one guard)' {
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO", "value": "1" },
    "oops"
]
"@
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*envVars.entries[[]1[]]*"
    }

    It 'throws when name is missing' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'name'*"
    }

    It 'throws when value is missing' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO" }]') } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'value'*"
    }

    It 'throws on an unknown sub-field naming the offending key' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "1", "default": "x" }]') } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'default'*"
    }

    It "throws on an 'append' sub-field (no support in v1)" {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "1", "append": true }]') } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'append'*"
    }
}

Describe 'Assert-VmEnvVarsField - name validation' {

    It 'rejects a name starting with a digit' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "1FOO", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name '1FOO'*POSIX identifier*"
    }

    It 'rejects a name containing a dash' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO-BAR", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name 'FOO-BAR'*POSIX identifier*"
    }

    It 'rejects a name containing whitespace' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO BAR", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name 'FOO BAR'*POSIX identifier*"
    }

    It 'rejects an empty name' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*POSIX identifier*"
    }

    It "rejects a name containing '=' (caught by the identifier regex)" {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO=", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name 'FOO='*"
    }
}

Describe 'Assert-VmEnvVarsField - value validation' {

    It 'rejects an empty value' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "" }]') } |
            Should -Throw -ExpectedMessage "*value must be a non-empty string*"
    }

    It 'rejects a value containing a newline (LF)' {
        # JSON encodes the LF; ConvertFrom-Json decodes back to a real \n.
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "a\nb" }]') } |
            Should -Throw -ExpectedMessage "*newline (LF)*"
    }

    It 'rejects a value containing a carriage return (CR)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "a\rb" }]') } |
            Should -Throw -ExpectedMessage "*carriage return (CR)*"
    }

    It 'rejects a value containing a NUL byte' {
        # Construct via host object so the source file stays clean
        # ASCII; the JSON path here would either be stripped or break
        # the parser depending on input encoding.
        $vm = New-VmWithSingleValue ("a" + [char]0 + "b")
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*NUL byte*"
    }
}

Describe 'Assert-VmEnvVarsField - duplicate name detection' {

    It 'throws when two entries share a name' {
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO", "value": "1" },
    { "name": "FOO", "value": "2" }
]
"@
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*duplicate entries for name 'FOO'*"
    }

    It 'surfaces a malformed-entry error before a duplicate-name error' {
        # Locks the documented ordering: shape first, dup-detection
        # second, so an operator chasing a 'duplicate' message is
        # never distracted from the real bug in a malformed entry.
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO", "value": "1" },
    { "name": "FOO" }
]
"@
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'value'*"
    }
}

function Test-DiagnosticText {
    param(
        [Parameter(Mandatory = $true)] [string]$Text,
        [Parameter(Mandatory = $true)] [string]$CurrentUserName
    )

    $Violations = New-Object System.Collections.Generic.List[string]
    if ($CurrentUserName.Length -ge 3 -and
        $Text.IndexOf($CurrentUserName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $Violations.Add("current_user_name")
    }
    if ($Text -match '(?i)[a-z]:\\+users\\+') {
        $Violations.Add("windows_user_path")
    }
    if ($Text -match '(?i)"(userName|commandLine|filePath|nonce|sid|token)"\s*:') {
        $Violations.Add("forbidden_field")
    }
    if ($Text -match '(?i)S-1-5-21-[0-9-]+') {
        $Violations.Add("account_sid")
    }
    return @($Violations)
}

function Test-DiagnosticDirectoryPrivacy {
    param(
        [Parameter(Mandatory = $true)] [string]$Directory,
        [Parameter(Mandatory = $true)] [string]$CurrentUserName
    )

    $Violations = New-Object System.Collections.Generic.List[string]
    $Files = @(Get-ChildItem -LiteralPath $Directory -File)
    foreach ($File in $Files) {
        $Text = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
        foreach ($Violation in @(Test-DiagnosticText -Text $Text -CurrentUserName $CurrentUserName)) {
            $Violations.Add(("{0}:{1}" -f $File.Name, $Violation))
        }
    }
    return [pscustomobject]@{
        passed = $Violations.Count -eq 0
        checkedFileCount = $Files.Count
        violations = @($Violations)
    }
}

function Test-DiagnosticArchivePrivacy {
    param(
        [Parameter(Mandatory = $true)] [string]$ArchivePath,
        [Parameter(Mandatory = $true)] [string]$CurrentUserName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Violations = New-Object System.Collections.Generic.List[string]
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($Entry in $Archive.Entries) {
            $Reader = New-Object System.IO.StreamReader($Entry.Open(), [System.Text.Encoding]::UTF8)
            try {
                $Text = $Reader.ReadToEnd()
            }
            finally {
                $Reader.Dispose()
            }
            foreach ($Violation in @(Test-DiagnosticText -Text $Text -CurrentUserName $CurrentUserName)) {
                $Violations.Add(("{0}:{1}" -f $Entry.FullName, $Violation))
            }
        }
        return [pscustomobject]@{
            passed = $Violations.Count -eq 0
            checkedFileCount = $Archive.Entries.Count
            violations = @($Violations)
        }
    }
    finally {
        $Archive.Dispose()
    }
}

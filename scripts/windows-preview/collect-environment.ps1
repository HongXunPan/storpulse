function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsSnapshot {
    $CurrentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $Build = [int]$CurrentVersion.CurrentBuildNumber
    $ProductName = [string]$CurrentVersion.ProductName
    $DisplayVersionProperty = $CurrentVersion.PSObject.Properties["DisplayVersion"]
    $UbrProperty = $CurrentVersion.PSObject.Properties["UBR"]
    $EvidenceClass = if ($ProductName -match "Server") {
        "server_exploratory"
    }
    elseif ($Build -ge 22000) {
        "windows_11_preliminary"
    }
    elseif ($Build -ge 19045) {
        "windows_10_22h2_candidate"
    }
    else {
        "older_windows_exploratory"
    }

    return [ordered]@{
        productName = $ProductName
        displayVersion = if ($null -ne $DisplayVersionProperty) { [string]$DisplayVersionProperty.Value } else { "unknown" }
        buildNumber = $Build
        updateBuildRevision = if ($null -ne $UbrProperty) { [int]$UbrProperty.Value } else { $null }
        architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        evidenceClass = $EvidenceClass
    }
}

function Get-InstalledServiceState {
    param(
        [Parameter(Mandatory = $true)] [string]$ServiceName,
        [Parameter(Mandatory = $true)] [string]$InstalledServicePath,
        [Parameter(Mandatory = $true)] [string]$ExpectedSha256
    )

    $ServiceRecord = Get-CimInstance -ClassName Win32_Service `
        -Filter ("Name='{0}'" -f $ServiceName)
    $Installed = $null -ne $ServiceRecord -and
        (Test-Path -LiteralPath $InstalledServicePath -PathType Leaf)
    if (-not $Installed) {
        return [pscustomobject]@{
            installed = $false
            configReadable = $false
            manual = $false
            localSystem = $false
            pathMatches = $false
            hashMatches = $false
        }
    }

    $ExpectedPath = ('"{0}"' -f $InstalledServicePath)
    $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledServicePath).Hash
    return [pscustomobject]@{
        installed = $true
        configReadable = -not [string]::IsNullOrWhiteSpace([string]$ServiceRecord.StartMode) -and
            -not [string]::IsNullOrWhiteSpace([string]$ServiceRecord.StartName) -and
            -not [string]::IsNullOrWhiteSpace([string]$ServiceRecord.PathName)
        manual = $ServiceRecord.StartMode -eq "Manual"
        localSystem = $ServiceRecord.StartName -eq "LocalSystem"
        pathMatches = [string]::Equals(
            ([string]$ServiceRecord.PathName).Trim(),
            $ExpectedPath,
            [StringComparison]::OrdinalIgnoreCase
        )
        hashMatches = $ActualHash.ToLowerInvariant() -eq $ExpectedSha256.ToLowerInvariant()
    }
}

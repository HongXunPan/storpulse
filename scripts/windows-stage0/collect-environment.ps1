function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PerformanceLogUser {
    try {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        $Sid = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-559")
        return $Principal.IsInRole($Sid)
    }
    catch {
        return $null
    }
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

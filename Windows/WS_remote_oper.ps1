#############################################################################################################
## Description: Copy or update selected files from the local machine to multiple remote Windows machines.
## Author: Matteo Z.
#############################################################################################################

[CmdletBinding()]
param(
    [string] $PathOper = "C:\temp",
    [string] $SystemList,
    [string] $ObjectList,
    [string] $LogPath
)

$script:ScriptName = $MyInvocation.MyCommand.Name
$script:LogHealthy = $true

# These values are resolved here instead of directly in param(), because their defaults
# depend on another parameter ($PathOper) and the log name also contains a timestamp.
if ([string]::IsNullOrWhiteSpace($SystemList)) {
    $SystemList = Join-Path $PathOper "system.txt"
}
if ([string]::IsNullOrWhiteSpace($ObjectList)) {
    $ObjectList = Join-Path $PathOper "object.txt"
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PathOper ("log-{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
}

function Show-Usage {
    Write-Host -ForegroundColor Red "`nDescription:"
    Write-Host "   Executes copy/update operations between Windows systems."
    Write-Host "`n   Windows systems: $SystemList"
    Write-Host "   Objects to copy: $ObjectList"
    Write-Host "   Log file: $LogPath"
    Write-Host "`n   System format: <hostname>,<ip address>"
    Write-Host "`n   Object formats:"
    Write-Host "    file:C:\temp\test.txt                 - copy/update one file"
    Write-Host "    file:C:\temp\test*                    - copy/update matching files"
    Write-Host "    file:C:\temp\*txt:test.txt,prova.txt  - exclude the listed names"
    Write-Host "    dir:C:\temp\test                      - copy a directory recursively"
    Write-Host "    dir:C:\temp\*:old,backup              - exclude these names recursively"
    Write-Host "    C:\temp\test.txt                      - same as file:C:\temp\test.txt"
    Write-Host "    #file:C:\temp\skip.txt                - comment/skip a row"
    Write-Host -ForegroundColor Red "`nUsage:"
    Write-Host "   $script:ScriptName [-PathOper <path>] [-SystemList <file>] [-ObjectList <file>] [-LogPath <file>]`n"
}

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message" -Encoding UTF8 -ErrorAction Stop
    } catch {
        $script:LogHealthy = $false
        Write-Warning "Unable to write to log '$LogPath': $($_.Exception.Message)"
    }
}

function Write-Status {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ConsoleColor] $Color = [ConsoleColor]::White
    )
    Write-Host -ForegroundColor $Color $Message
    Write-Log $Message
}

function New-CopyResult {
    param([int] $Copied = 0, [int] $Skipped = 0, [int] $Failed = 0)
    [PSCustomObject]@{ Copied = $Copied; Skipped = $Skipped; Failed = $Failed }
}

function Split-ObjectSpecification {
    param([Parameter(Mandatory)][string] $Line)

    $cleanLine = $Line.Trim()
    $mode = "file"
    $exclusions = @()

    if ($cleanLine -match '^(?i)(file|dir):(.+)$') {
        $mode = $matches[1].ToLowerInvariant()
        $cleanLine = $matches[2].Trim()
    }

    # The first colon belongs to the drive letter (C:). Any following colon separates
    # the source pattern from the optional comma-separated exclusion list.
    # Example: C:\temp\*txt:test.txt,prova.txt
    $separatorIndex = $cleanLine.IndexOf(':', 2)
    if ($separatorIndex -ge 0) {
        $pattern = $cleanLine.Substring(0, $separatorIndex).Trim()
        $exclusionText = $cleanLine.Substring($separatorIndex + 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($exclusionText)) {
            $exclusions = @($exclusionText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    } else {
        $pattern = $cleanLine
    }

    [PSCustomObject]@{ Mode = $mode; Pattern = $pattern; Exclusions = [string[]]$exclusions }
}

function Get-ObjectSpecifications {
    try {
        $lines = @(Get-Content -LiteralPath $ObjectList -ErrorAction Stop)
    } catch {
        Write-Status "Unable to read object list '$ObjectList': $($_.Exception.Message)" Red
        return $null
    }

    $specifications = @()
    foreach ($line in $lines) {
        $cleanLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($cleanLine) -or $cleanLine.StartsWith('#')) { continue }

        $specification = Split-ObjectSpecification $cleanLine
        if ([string]::IsNullOrWhiteSpace($specification.Pattern)) {
            Write-Status "Invalid empty object specification: '$line'" Red
            continue
        }
        $specifications += $specification
    }

    if ($specifications.Count -eq 0) {
        Write-Status "No valid objects were found in '$ObjectList'." Red
        return $null
    }
    return ,$specifications
}

function Get-SourceItems {
    param(
        [Parameter(Mandatory)][string] $LocalPattern,
        [Parameter(Mandatory)][ValidateSet("file", "dir")][string] $Mode
    )

    $items = @()
    $hadErrors = $false
    try {
        # -LiteralPath protects the parent directory from wildcard expansion, while
        # -Filter applies wildcards only to the final path component. Consequently,
        # wildcard characters in intermediate directories are intentionally unsupported.
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($LocalPattern)) {
            $parentPath = Split-Path -Path $LocalPattern -Parent
            $leafFilter = Split-Path -Path $LocalPattern -Leaf
            if ([string]::IsNullOrWhiteSpace($parentPath)) { $parentPath = "." }
            if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
                Write-Status "Source directory not found: $parentPath" Yellow
                return [PSCustomObject]@{ Items = @(); HadErrors = $true }
            }
            if ($Mode -eq "dir") {
                $items = @(Get-ChildItem -LiteralPath $parentPath -Filter $leafFilter -Directory -ErrorAction Stop)
            } else {
                $items = @(Get-ChildItem -LiteralPath $parentPath -Filter $leafFilter -File -ErrorAction Stop)
            }
        } elseif ($Mode -eq "dir" -and (Test-Path -LiteralPath $LocalPattern -PathType Container)) {
            $items = @(Get-Item -LiteralPath $LocalPattern -ErrorAction Stop)
        } elseif ($Mode -eq "file" -and (Test-Path -LiteralPath $LocalPattern -PathType Leaf)) {
            $items = @(Get-Item -LiteralPath $LocalPattern -ErrorAction Stop)
        } else {
            Write-Status "Source $Mode not found: $LocalPattern" Yellow
            $hadErrors = $true
        }
    } catch {
        Write-Status "Unable to resolve source '$LocalPattern': $($_.Exception.Message)" Red
        $hadErrors = $true
    }
    [PSCustomObject]@{ Items = $items; HadErrors = $hadErrors }
}

function Get-RemoteDestinationPath {
    param(
        [Parameter(Mandatory)][string] $DriveName,
        [Parameter(Mandatory)][System.IO.FileSystemInfo] $Item
    )

    if ($Item.FullName -notmatch '^[A-Za-z]:\\') {
        Write-Status "Unsupported source path format: $($Item.FullName)" Yellow
        return $null
    }
    $driveLetter = $Item.FullName.Substring(0, 1).ToUpperInvariant()
    if ($driveLetter -ne "C") {
        Write-Status "The remote share is C$. Source '$($Item.FullName)' on drive $driveLetter`: was ignored." Yellow
        return $null
    }

    # The mapped PSDrive points to the remote C$ share. Removing "C:\" from the local
    # path and appending the remainder preserves the same absolute path remotely:
    # C:\temp\a.txt -> WSRxxxxxx:\temp\a.txt -> \\host\C$\temp\a.txt.
    Join-Path "$DriveName`:\" $Item.FullName.Substring(3)
}

function Test-ExcludedName {
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowEmptyCollection()][string[]] $Exclusions = @()
    )
    return ($Exclusions -contains $Name)
}

function Copy-FileToRemote {
    param(
        [Parameter(Mandatory)][string] $DriveName,
        [Parameter(Mandatory)][System.IO.FileInfo] $File
    )

    $destination = Get-RemoteDestinationPath $DriveName $File
    if ([string]::IsNullOrWhiteSpace($destination)) { return New-CopyResult -Skipped 1 }

    try {
        $destinationDirectory = Split-Path $destination -Parent
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
            New-Item -Path $destinationDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Created directory: $destinationDirectory"
        }
        Copy-Item -LiteralPath $File.FullName -Destination $destination -Force -ErrorAction Stop
        Write-Status "Copied file: $($File.FullName) to $destination" Green
        return New-CopyResult -Copied 1
    } catch {
        Write-Status "Failed to copy file '$($File.FullName)' to '$destination': $($_.Exception.Message)" Red
        return New-CopyResult -Failed 1
    }
}

function Copy-DirectoryToRemote {
    param(
        [Parameter(Mandatory)][string] $DriveName,
        [Parameter(Mandatory)][System.IO.DirectoryInfo] $Directory,
        [AllowEmptyCollection()][string[]] $Exclusions = @()
    )

    $result = New-CopyResult
    $destination = Get-RemoteDestinationPath $DriveName $Directory
    if ([string]::IsNullOrWhiteSpace($destination)) { return New-CopyResult -Skipped 1 }

    try {
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            New-Item -Path $destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Created directory: $destination"
        }
    } catch {
        Write-Status "Failed to create destination directory '$destination': $($_.Exception.Message)" Red
        return New-CopyResult -Failed 1
    }

    # Walk the tree explicitly instead of using Get-ChildItem -Recurse. This allows an
    # excluded directory to be pruned before it is enumerated, avoiding unnecessary I/O
    # and access errors in content that the user does not want to copy.
    $pendingDirectories = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $pendingDirectories.Enqueue($Directory)

    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Dequeue()
        try {
            $children = @(Get-ChildItem -LiteralPath $currentDirectory.FullName -Force -ErrorAction Stop)
        } catch {
            $result.Failed++
            Write-Status "Failed to enumerate '$($currentDirectory.FullName)': $($_.Exception.Message)" Red
            continue
        }

        foreach ($child in $children) {
            $relativePath = $child.FullName.Substring($Directory.FullName.Length).TrimStart('\')
            if (Test-ExcludedName $child.Name $Exclusions) {
                $result.Skipped++
                Write-Log "Skipped by exclusion: $($child.FullName)"
                continue
            }

            $childDestination = Join-Path $destination $relativePath
            if ($child.PSIsContainer) {
                # Junctions and symbolic-link directories may lead outside the requested
                # tree or create cycles. Skip them rather than following or recreating them.
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $result.Skipped++
                    Write-Status "Skipped reparse point: $($child.FullName)" Yellow
                    continue
                }
                try {
                    if (-not (Test-Path -LiteralPath $childDestination -PathType Container)) {
                        New-Item -Path $childDestination -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        Write-Log "Created directory: $childDestination"
                    }
                    $pendingDirectories.Enqueue([System.IO.DirectoryInfo]$child)
                } catch {
                    $result.Failed++
                    Write-Status "Failed to create directory '$childDestination': $($_.Exception.Message)" Red
                }
                continue
            }

            try {
                $childDestinationDirectory = Split-Path $childDestination -Parent
                if (-not (Test-Path -LiteralPath $childDestinationDirectory -PathType Container)) {
                    New-Item -Path $childDestinationDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                Copy-Item -LiteralPath $child.FullName -Destination $childDestination -Force -ErrorAction Stop
                $result.Copied++
                Write-Log "Copied file: $($child.FullName) to $childDestination"
            } catch {
                $result.Failed++
                Write-Status "Failed to copy '$($child.FullName)' to '$childDestination': $($_.Exception.Message)" Red
            }
        }
    }

    $color = if ($result.Failed -eq 0) { "Green" } else { "Yellow" }
    Write-Status "Directory completed: $($Directory.FullName) (copied=$($result.Copied), skipped=$($result.Skipped), failed=$($result.Failed))" $color
    return $result
}

function Copy-ObjectsToRemote {
    param(
        [Parameter(Mandatory)][string] $DriveName,
        [Parameter(Mandatory)][ValidateSet("file", "dir")][string] $Mode,
        [Parameter(Mandatory)][string] $LocalPattern,
        [AllowEmptyCollection()][string[]] $Exclusions = @()
    )

    $result = New-CopyResult
    $sourceResult = Get-SourceItems $LocalPattern $Mode
    if ($sourceResult.HadErrors) { $result.Failed++ }
    if ($sourceResult.Items.Count -eq 0) {
        Write-Status "No $Mode items found for pattern: $LocalPattern" Yellow
        if (-not $sourceResult.HadErrors) { $result.Failed++ }
        return $result
    }

    foreach ($item in $sourceResult.Items) {
        if (Test-ExcludedName $item.Name $Exclusions) {
            $result.Skipped++
            Write-Log "Skipped by exclusion: $($item.FullName)"
            continue
        }
        if ($Mode -eq "dir") {
            $itemResult = Copy-DirectoryToRemote $DriveName $item $Exclusions
        } else {
            $itemResult = Copy-FileToRemote $DriveName $item
        }

        # Each lower-level copy operation returns counters rather than a simple Boolean,
        # so partial success is retained and included in the final per-host summary.
        $result.Copied += $itemResult.Copied
        $result.Skipped += $itemResult.Skipped
        $result.Failed += $itemResult.Failed
    }
    return $result
}

function Test-SmbEndpoint {
    param([Parameter(Mandatory)][string] $Endpoint)
    try {
        return [bool](Test-NetConnection -ComputerName $Endpoint -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop)
    } catch {
        Write-Status "Unable to test port 445 on '$Endpoint': $($_.Exception.Message)" Yellow
        return $false
    }
}

function Invoke-RemoteCopy {
    param(
        [Parameter(Mandatory)][string] $Hostname,
        [string] $Ip,
        [Parameter(Mandatory)][PSCredential] $Credential,
        [Parameter(Mandatory)][object[]] $Specifications
    )

    $result = New-CopyResult
    $remoteEndpoint = $Hostname
    $portOpen = Test-SmbEndpoint $remoteEndpoint

    # Prefer the hostname so logs and SMB authentication use the machine identity.
    # Fall back to the configured IP only when port 445 is unreachable by hostname.
    if (-not $portOpen -and -not [string]::IsNullOrWhiteSpace($Ip) -and $Ip -ne $Hostname) {
        $remoteEndpoint = $Ip
        $portOpen = Test-SmbEndpoint $remoteEndpoint
    }
    if (-not $portOpen) {
        Write-Status "Port 445 is closed or unreachable on $Hostname ($Ip)" Red
        return New-CopyResult -Failed 1
    }

    Write-Status "Port 445 is open on $remoteEndpoint ($Hostname)" Green
    $remoteShare = "\\$remoteEndpoint\C$"

    # A unique drive name prevents collisions with existing PSDrives or concurrent runs.
    $driveName = "WSR$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    try {
        New-PSDrive -Name $driveName -PSProvider FileSystem -Root $remoteShare -Credential $Credential -ErrorAction Stop | Out-Null
        Write-Status "Successfully mapped $remoteShare to $driveName`:" Green
    } catch {
        Write-Status "Failed to map ${remoteShare}: $($_.Exception.Message)" Red
        return New-CopyResult -Failed 1
    }

    try {
        foreach ($specification in $Specifications) {
            $copyResult = Copy-ObjectsToRemote $driveName $specification.Mode $specification.Pattern $specification.Exclusions
            $result.Copied += $copyResult.Copied
            $result.Skipped += $copyResult.Skipped
            $result.Failed += $copyResult.Failed
        }
    } catch {
        $result.Failed++
        Write-Status "Unexpected copy error for ${Hostname}: $($_.Exception.Message)" Red
    } finally {
        try {
            if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
                Remove-PSDrive -Name $driveName -Force -ErrorAction Stop
                Write-Status "Disconnected $driveName`:" Green
            }
        } catch {
            $result.Failed++
            Write-Status "Failed to disconnect $driveName`: $($_.Exception.Message)" Red
        }
    }

    $color = if ($result.Failed -eq 0) { "Green" } else { "Yellow" }
    Write-Status "System completed: $Hostname (copied=$($result.Copied), skipped=$($result.Skipped), failed=$($result.Failed))" $color
    return $result
}

function Invoke-Main {
    try {
        if (-not (Test-Path -LiteralPath $PathOper -PathType Container)) {
            New-Item -Path $PathOper -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $logDirectory = Split-Path $LogPath -Parent
        if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Host -ForegroundColor Red "Unable to initialize working/log directory: $($_.Exception.Message)"
        return 1
    }

    if (-not (Test-Path -LiteralPath $SystemList -PathType Leaf)) {
        Write-Status "The Windows system list '$SystemList' does not exist." Yellow
        Show-Usage
        return 1
    }
    if (-not (Test-Path -LiteralPath $ObjectList -PathType Leaf)) {
        Write-Status "The object list '$ObjectList' does not exist." Yellow
        Show-Usage
        return 1
    }

    # Parse the object list once. Reusing the validated specifications for every host
    # avoids rereading the file and guarantees that all hosts receive the same operation.
    $specifications = Get-ObjectSpecifications
    if ($null -eq $specifications -or $specifications.Count -eq 0) { return 1 }

    try {
        $systemLines = @(Get-Content -LiteralPath $SystemList -ErrorAction Stop)
    } catch {
        Write-Status "Unable to read system list '$SystemList': $($_.Exception.Message)" Red
        return 1
    }

    $systems = @()
    $configurationErrors = 0
    foreach ($line in $systemLines) {
        $cleanSystem = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($cleanSystem) -or $cleanSystem.StartsWith('#')) { continue }
        $parts = @($cleanSystem -split ',', 2)
        $hostname = $parts[0].Trim()
        $ip = if ($parts.Count -eq 2) { $parts[1].Trim() } else { "" }
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($hostname)) {
            $configurationErrors++
            Write-Status "Invalid entry in '$SystemList': $cleanSystem" Red
            continue
        }
        $systems += [PSCustomObject]@{ Hostname = $hostname; Ip = $ip }
    }
    if ($systems.Count -eq 0) {
        Write-Status "No valid systems were found in '$SystemList'." Red
        return 1
    }

    try {
        $credential = Get-Credential -Message "Type the credential to log in to the remote Windows systems" -ErrorAction Stop
    } catch {
        Write-Status "Credential request failed or was cancelled: $($_.Exception.Message)" Red
        return 1
    }
    if ($null -eq $credential) {
        Write-Status "Credential request was cancelled." Red
        return 1
    }

    # Invalid system-list rows count as failures even though valid rows are still processed.
    $total = New-CopyResult -Failed $configurationErrors
    foreach ($system in $systems) {
        Write-Status "`nProcessing remote system: $($system.Hostname) ($($system.Ip))" Cyan
        $systemResult = Invoke-RemoteCopy $system.Hostname $system.Ip $credential $specifications
        $total.Copied += $systemResult.Copied
        $total.Skipped += $systemResult.Skipped
        $total.Failed += $systemResult.Failed
    }

    $color = if ($total.Failed -eq 0 -and $script:LogHealthy) { "Green" } else { "Yellow" }
    Write-Status "`nOverall result: copied=$($total.Copied), skipped=$($total.Skipped), failed=$($total.Failed). Log: $LogPath" $color
    if ($total.Failed -gt 0 -or -not $script:LogHealthy) { return 1 }
    return 0
}

$exitCode = Invoke-Main

# Dot-sourcing is useful for tests or interactive troubleshooting: return the result
# without terminating the caller's PowerShell session. Normal execution uses an exit
# code that schedulers and CI systems can evaluate.
if ($MyInvocation.InvocationName -eq '.') { return $exitCode }
exit $exitCode

#############################################################################################################
## Description: Script to copy or update specific files from the local machine to multiple remote machines
##
## Author: Matteo Z.
#############################################################################################################

function print_usage {
	Write-Host -ForegroundColor "red" "`nDescription:"
	Write-Host "   Script that it executes some operations between 2 Windows systems (such as copying files or updating them)"
	Write-Host "`n   File with the list of the Windows system: $system_list"
    Write-Host "`n   File with all object that should be copied/updated on the remote system: $object_to_update"
	Write-Host "`n   Log file: $log"
	Write-Host "`n   The format of the file $system_list must be: <hostname1>,<ip address1>"
	Write-Host "                                                      ....."
	Write-Host "                                                      <hostnameN>,<ip addressN>"
	Write-Host "`n   The format of the file $object_to_update must be:`n"
	Write-Host "    file:C:\temp\test.txt             - to copy or update a specific file"
	Write-Host "    file:C:\temp\test*                - to copy or update all files that begin with the word 'test'"
	Write-Host "    file:C:\temp\*                    - to copy or update all files in a specific directory"
	Write-Host "    file:C:\temp\*txt:test.txt,prova.txt - to copy or update all files that end with the word 'txt', but the file 'test.txt' and 'prova.txt' that will be ignored"
	Write-Host "    dir:C:\temp\test                  - to copy or update a specific directory recursively"
	Write-Host "    dir:C:\temp\test*                 - to copy or update all directories that begin with the word 'test' recursively"
	Write-Host "    dir:C:\temp\*:old,backup          - to copy or update all directories, but the directories/files named 'old' and 'backup' will be ignored"
	Write-Host "    C:\temp\test.txt                  - same as file:C:\temp\test.txt"
	Write-Host "    #file:C:\temp\skip.txt            - to skip a specific row"
	Write-Host -ForegroundColor "red" "`nUsage:"
	Write-Host "`n  $script`n"
}

function write_log {
    param (
        [string] $message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $message" | Out-File -FilePath $log -Append
}

function write_status {
    param (
        [string] $message,
        [string] $color = "white"
    )

    Write-Host -ForegroundColor $color $message
    write_log $message
}

function split_object_spec {
    param (
        [string] $line
    )

    $clean_line = $line.Trim()
    $exclusions = @()
    $mode = "file"

    if ($clean_line -match '^(?i)(file|dir):(.+)$') {
        $mode = $matches[1].ToLowerInvariant()
        $clean_line = $matches[2].Trim()
    }

    # Skip the drive separator (for example C:) and use the next ':' as exclusion separator.
    $separator_index = $clean_line.IndexOf(':', 2)

    if ($separator_index -ge 0) {
        $pattern = $clean_line.Substring(0, $separator_index).Trim()
        $exclusion_text = $clean_line.Substring($separator_index + 1).Trim()

        if (-not [string]::IsNullOrWhiteSpace($exclusion_text)) {
            $exclusions = @(
                $exclusion_text -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne "" }
            )
        }
    } else {
        $pattern = $clean_line
    }

    return [PSCustomObject]@{
        Mode = $mode
        Pattern = $pattern
        Exclusions = $exclusions
    }
}

function get_items_from_pattern {
    param(
        [string] $localPattern,
        [ValidateSet("file", "dir")]
        [string] $mode
    )

    if ([string]::IsNullOrWhiteSpace($localPattern)) {
        return @()
    }

    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($localPattern)) {
        $parent_path = Split-Path -Path $localPattern -Parent
        $leaf_filter = Split-Path -Path $localPattern -Leaf

        if ([string]::IsNullOrWhiteSpace($parent_path)) {
            $parent_path = "."
        }

        if (-not (Test-Path -LiteralPath $parent_path -PathType Container)) {
            write_status "Warning!! Source directory not found: $parent_path" "yellow"
            return @()
        }

        if ($mode -eq "dir") {
            return @(
                Get-ChildItem -LiteralPath $parent_path -Filter $leaf_filter -Directory -ErrorAction SilentlyContinue
            )
        }

        return @(
            Get-ChildItem -LiteralPath $parent_path -Filter $leaf_filter -File -ErrorAction SilentlyContinue
        )
    }

    if ($mode -eq "dir" -and (Test-Path -LiteralPath $localPattern -PathType Container)) {
        return @(
            Get-Item -LiteralPath $localPattern
        )
    }

    if ($mode -eq "file" -and (Test-Path -LiteralPath $localPattern -PathType Leaf)) {
        return @(
            Get-Item -LiteralPath $localPattern
        )
    }

    write_status "Warning!! Source $mode not found: $localPattern" "yellow"
    return @()
}

function get_remote_destination_path {
    param(
        [string] $driveName,
        [System.IO.FileSystemInfo] $item
    )

    if ($item.FullName -notmatch '^[A-Za-z]:\\') {
        write_status "Warning!! Unsupported source path format: $($item.FullName)" "yellow"
        return $null
    }

    $drive_letter = $item.FullName.Substring(0, 1).ToUpperInvariant()

    if ($drive_letter -ne "C") {
        write_status "Warning!! The remote share is C$, source '$($item.FullName)' will be ignored because it is on drive $drive_letter`:" "yellow"
        return $null
    }

    $relative_path = $item.FullName.Substring(3)
    return Join-Path -Path "$driveName`:\" -ChildPath $relative_path
}

function test_excluded_item {
    param(
        [System.IO.FileSystemInfo] $item,
        [string[]] $exclusions
    )

    return ($exclusions -contains $item.Name)
}

function test_excluded_relative_path {
    param(
        [string] $relativePath,
        [string[]] $exclusions
    )

    if ($exclusions.Length -eq 0) {
        return $false
    }

    $path_parts = @($relativePath -split '[\\/]') | Where-Object { $_ -ne "" }

    foreach ($part in $path_parts) {
        if ($exclusions -contains $part) {
            return $true
        }
    }

    return $false
}

function copy_file_to_remote {
    param(
        [string] $driveName,
        [System.IO.FileInfo] $file
    )

    $destination = get_remote_destination_path -driveName $driveName -item $file

    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }

    $destinationDir = Split-Path -Path $destination -Parent

    try {
        if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
            New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
            write_log "Created directory: $destinationDir"
        }

        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
        write_status "Copied file: $($file.FullName) to $destination" "green"
    } catch {
        write_status "Failed to copy file '$($file.FullName)' to '$destination': $_" "red"
    }
}

function copy_directory_to_remote {
    param(
        [string] $driveName,
        [System.IO.DirectoryInfo] $directory,
        [string[]] $exclusions
    )

    $destination = get_remote_destination_path -driveName $driveName -item $directory

    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
            write_log "Created directory: $destination"
        }

        $children = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue)

        foreach ($child in $children) {
            $relative_child_path = $child.FullName.Substring($directory.FullName.Length).TrimStart('\')

            if (test_excluded_relative_path -relativePath $relative_child_path -exclusions $exclusions) {
                write_log "Skipped by exclusion: $($child.FullName)"
                continue
            }

            $child_destination = Join-Path -Path $destination -ChildPath $relative_child_path

            if ($child.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $child_destination -PathType Container)) {
                    New-Item -Path $child_destination -ItemType Directory -Force | Out-Null
                    write_log "Created directory: $child_destination"
                }
            } else {
                $child_destination_dir = Split-Path -Path $child_destination -Parent

                if (-not (Test-Path -LiteralPath $child_destination_dir -PathType Container)) {
                    New-Item -Path $child_destination_dir -ItemType Directory -Force | Out-Null
                    write_log "Created directory: $child_destination_dir"
                }

                Copy-Item -LiteralPath $child.FullName -Destination $child_destination -Force -ErrorAction Stop
                write_log "Copied file: $($child.FullName) to $child_destination"
            }
        }

        write_status "Copied directory: $($directory.FullName) to $destination" "green"
    } catch {
        write_status "Failed to copy directory '$($directory.FullName)' to '$destination': $_" "red"
    }
}

function copy_objects_to_remote {
    param(
        [string] $driveName,
        [string] $mode,
        [string] $localPattern,
        [string[]] $exclusions
    )

    $items = @(get_items_from_pattern -localPattern $localPattern -mode $mode)

    if ($items.Length -eq 0) {
        write_status "Warning!! No $mode items found for pattern: $localPattern" "yellow"
        return
    }

    foreach ($item in $items) {
        if (test_excluded_item -item $item -exclusions $exclusions) {
            write_log "Skipped by exclusion: $($item.FullName)"
            continue
        }

        if ($mode -eq "dir") {
            copy_directory_to_remote -driveName $driveName -directory $item -exclusions $exclusions
        } else {
            copy_file_to_remote -driveName $driveName -file $item
        }
    }
}

function map_share {
    param(
        [string] $hostname,
        [string] $ip,
        [PSCredential] $credential
    )

    $remote_endpoint = $hostname
    $test_port = Test-NetConnection -ComputerName $remote_endpoint -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue

    if (-not $test_port -and -not [string]::IsNullOrWhiteSpace($ip)) {
        $remote_endpoint = $ip
        $test_port = Test-NetConnection -ComputerName $remote_endpoint -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue
    }

    if ($test_port) {
        write_status "Port 445 is open on $remote_endpoint ($hostname)" "green"

        $remote_share = "\\$remote_endpoint\C$"
        $driveName = "WSR$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        
        try {
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $remote_share -Credential $credential -ErrorAction Stop | Out-Null
            write_status "Successfully mapped $remote_share to $driveName`:" "green"

            foreach ($line in Get-Content $object_to_update) {
                $clean_line = $line.Trim()

                if ([string]::IsNullOrWhiteSpace($clean_line) -or $clean_line.StartsWith("#")) {
                    continue
                }

                $object_spec = split_object_spec -line $clean_line
                copy_objects_to_remote -driveName $driveName -mode $object_spec.Mode -localPattern $object_spec.Pattern -exclusions $object_spec.Exclusions
            }
        } catch {
            write_status "Failed to map $remote_share to $driveName`: $_" "red"
        } finally {
            if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
                Remove-PSDrive -Name $driveName -Force
                write_status "Disconnected $driveName`:" "green"
            }
        }
    } else {
        write_status "Port 445 is closed on $hostname ($ip)" "red"
    }
}

function main {
    if (-not (Test-Path $path_oper -PathType Container)) {
        New-Item -Path $path_oper -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $system_list)) {
        $message = "`nWarning!! The file with the list of all Windows systems '$system_list' doesn't exist!"
        Write-Host -ForegroundColor "yellow" $message
        write_log $message
        print_usage
    } else {
        if (-not (Test-Path $object_to_update)) {
            $message = "`nWarning!! The file with all objects to be copied/updated '$object_to_update' doesn't exist!"
            Write-Host -ForegroundColor "yellow" $message
            write_log $message
            print_usage
        } else {
            $credential = Get-Credential -Message "Type the credential to login on remote Windows systems"

            foreach ($system in Get-Content $system_list) {
                $clean_system = $system.Trim()

                if ([string]::IsNullOrWhiteSpace($clean_system) -or $clean_system.StartsWith("#")) {
                    continue
                }

                $parts = $clean_system -split ','

                if ($parts.Length -eq 2) {
                    $hostname = $parts[0].Trim()
                    $ip = $parts[1].Trim()
                    write_status "`nProcessing remote system: $hostname ($ip)" "cyan"
                    map_share -hostname $hostname -ip $ip -credential $credential
                } else {
                    $message = "Invalid entry in $system_list ($clean_system)"
                    Write-Host -ForegroundColor "red" $message
                    write_log $message
                }
            }

            if ((Test-Path $log -PathType Leaf) -and ((Get-Item $log).Length -gt 0)) {
                Write-Host "The file '$log' has been created, you should check it!"
            }
        }
    }
}


########## MAIN ##########

$script = $MyInvocation.MyCommand.Name
$date = Get-Date -f yyyy-MM-dd_HH-mm-ss
$path_oper = "C:\temp"
$system_list = "$path_oper\system.txt"
$object_to_update = "$path_oper\object.txt"
$log = "$path_oper\log-$date.log"
main

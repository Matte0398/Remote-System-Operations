#############################################################################################################
## Description: Script to copy or update specific files/directories from the local machine to multiple
##              remote Windows machines using PowerShell Remoting (WinRM)
##
## Author: Matteo Z.
#############################################################################################################

function print_usage {
    Write-Host -ForegroundColor "red" "`nDescription:"
    Write-Host "`n   Script that copies or updates files/directories from the local Windows machine to multiple remote Windows systems using WinRM."
    Write-Host "`n   File with the list of Windows systems: $system_list"
    Write-Host "`n   File with all objects that should be copied/updated on the remote systems: $object_to_update"
    Write-Host "`n   Log file: $log"
    Write-Host "`n   The format of $system_list must be: <hostname>,<ip_address>"
    Write-Host "`n   Example:"
    Write-Host "      server01,192.168.1.10"
    Write-Host "      server02,192.168.1.11"
    Write-Host "`n   The format of $object_to_update must be:`n"
    Write-Host "      file:C:\temp\test.txt                  - copy/update a specific file"
    Write-Host "      file:C:\temp\test*                     - copy/update all files that begin with 'test'"
    Write-Host "      file:C:\temp\*                         - copy/update all files in a specific directory"
    Write-Host "      file:C:\temp\*txt:test.txt,prova.txt   - copy/update all files ending with 'txt', excluding test.txt and prova.txt"
    Write-Host "      dir:C:\temp\test                       - copy/update a specific directory recursively"
    Write-Host "      dir:C:\temp\test*                      - copy/update all directories that begin with 'test' recursively"
    Write-Host "      dir:C:\temp\*:old,backup               - copy/update all directories, excluding objects named old and backup"
    Write-Host "      C:\temp\test.txt                       - same as file:C:\temp\test.txt"
    Write-Host "      #file:C:\temp\skip.txt                 - skip a row"
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

    # Skip the drive separator, for example C:, and use the next ':' as exclusion separator.
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
            return @(Get-ChildItem -LiteralPath $parent_path -Filter $leaf_filter -Directory -ErrorAction SilentlyContinue)
        }

        return @(Get-ChildItem -LiteralPath $parent_path -Filter $leaf_filter -File -ErrorAction SilentlyContinue)
    }

    if ($mode -eq "dir" -and (Test-Path -LiteralPath $localPattern -PathType Container)) {
        return @(Get-Item -LiteralPath $localPattern)
    }

    if ($mode -eq "file" -and (Test-Path -LiteralPath $localPattern -PathType Leaf)) {
        return @(Get-Item -LiteralPath $localPattern)
    }

    write_status "Warning!! Source $mode not found: $localPattern" "yellow"
    return @()
}


function get_remote_destination_path {
    param(
        [System.IO.FileSystemInfo] $item
    )

    if ($item.FullName -notmatch '^[A-Za-z]:\\') {
        write_status "Warning!! Unsupported source path format: $($item.FullName)" "yellow"
        return $null
    }

    # With WinRM/Copy-Item -ToSession we can use the same absolute path on the remote system,
    # for example C:\temp\file.txt -> C:\temp\file.txt on the remote server.
    return $item.FullName
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


function ensure_remote_directory {
    param(
        [System.Management.Automation.Runspaces.PSSession] $session,
        [string] $path
    )

    Invoke-Command -Session $session -ScriptBlock {
        param($remotePath)

        if (-not (Test-Path -LiteralPath $remotePath -PathType Container)) {
            New-Item -Path $remotePath -ItemType Directory -Force | Out-Null
        }
    } -ArgumentList $path -ErrorAction Stop
}


function copy_file_to_remote {
    param(
        [System.Management.Automation.Runspaces.PSSession] $session,
        [System.IO.FileInfo] $file
    )

    $destination = get_remote_destination_path -item $file

    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }

    $destinationDir = Split-Path -Path $destination -Parent

    try {
        ensure_remote_directory -session $session -path $destinationDir
        Copy-Item -LiteralPath $file.FullName -Destination $destination -ToSession $session -Force -ErrorAction Stop
        write_status "Copied file: $($file.FullName) to $destination" "green"
    } catch {
        write_status "Failed to copy file '$($file.FullName)' to '$destination': $_" "red"
    }
}


function copy_directory_to_remote {
    param(
        [System.Management.Automation.Runspaces.PSSession] $session,
        [System.IO.DirectoryInfo] $directory,
        [string[]] $exclusions
    )

    $destination = get_remote_destination_path -item $directory

    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }

    try {
        ensure_remote_directory -session $session -path $destination

        $children = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue)

        foreach ($child in $children) {
            $relative_child_path = $child.FullName.Substring($directory.FullName.Length).TrimStart('\')

            if (test_excluded_relative_path -relativePath $relative_child_path -exclusions $exclusions) {
                write_log "Skipped by exclusion: $($child.FullName)"
                continue
            }

            $child_destination = Join-Path -Path $destination -ChildPath $relative_child_path

            if ($child.PSIsContainer) {
                ensure_remote_directory -session $session -path $child_destination
            } else {
                $child_destination_dir = Split-Path -Path $child_destination -Parent
                ensure_remote_directory -session $session -path $child_destination_dir
                Copy-Item -LiteralPath $child.FullName -Destination $child_destination -ToSession $session -Force -ErrorAction Stop
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
        [System.Management.Automation.Runspaces.PSSession] $session,
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
            copy_directory_to_remote -session $session -directory $item -exclusions $exclusions
        } else {
            copy_file_to_remote -session $session -file $item
        }
    }
}


function open_remote_session {
    param(
        [string] $hostname,
        [string] $ip,
        [PSCredential] $credential
    )

    $remote_endpoint = $hostname
    $session = $null

    try {
        write_status "Testing WinRM on $remote_endpoint ($ip)" "cyan"
        Test-WSMan -ComputerName $remote_endpoint -ErrorAction Stop | Out-Null
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            try {
                write_status "WinRM test failed on hostname. Trying IP address $ip" "yellow"
                Test-WSMan -ComputerName $ip -ErrorAction Stop | Out-Null
                $remote_endpoint = $ip
            } catch {
                write_status "WinRM is not reachable on $hostname ($ip): $_" "red"
                return
            }
        } else {
            write_status "WinRM is not reachable on $hostname ($ip): $_" "red"
            return
        }
    }

    try {
        write_status "Opening PowerShell session to $remote_endpoint ($hostname)" "cyan"
        $session = New-PSSession -ComputerName $remote_endpoint -Credential $credential -ErrorAction Stop

        foreach ($line in Get-Content $object_to_update) {
            $clean_line = $line.Trim()

            if ([string]::IsNullOrWhiteSpace($clean_line) -or $clean_line.StartsWith("#")) {
                continue
            }

            $object_spec = split_object_spec -line $clean_line

            copy_objects_to_remote `
                -session $session `
                -mode $object_spec.Mode `
                -localPattern $object_spec.Pattern `
                -exclusions $object_spec.Exclusions
        }
    } catch {
        write_status "Failed to process $remote_endpoint ($hostname): $_" "red"
    } finally {
        if ($null -ne $session) {
            Remove-PSSession $session
            write_status "Closed PowerShell session to $remote_endpoint" "green"
        }
    }
}


function test_system_list_entry {
    param(
        [string] $clean_system
    )

    $parts = $clean_system -split ','

    if ($parts.Length -ne 2) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        return $false
    }

    return $true
}


function main {
    if (-not (Test-Path $path_oper -PathType Container)) {
        New-Item -Path $path_oper -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $system_list) -or (Get-Content $system_list).Length -eq 0) {
        $message = "`nWarning!! The file with the list of all Windows systems '$system_list' doesn't exist or it's empty!"
        Write-Host -ForegroundColor "yellow" $message
        write_log $message
        print_usage
        return
    }

    if (-not (Test-Path $object_to_update) -or (Get-Content $object_to_update).Length -eq 0) {
        $message = "`nWarning!! The file with all objects to be copied/updated '$object_to_update' doesn't exist or it's empty!"
        Write-Host -ForegroundColor "yellow" $message
        write_log $message
        print_usage
        return
    }

    # Validate system list before asking for credentials.
    $valid_systems = @()
    $invalid_found = $false

    foreach ($system in Get-Content $system_list) {
        $clean_system = $system.Trim()

        if ([string]::IsNullOrWhiteSpace($clean_system) -or $clean_system.StartsWith("#")) {
            continue
        }

        if (-not (test_system_list_entry -clean_system $clean_system)) {
            $message = "Invalid entry in $system_list ($clean_system)"
            Write-Host -ForegroundColor "red" $message
            write_log $message
            $invalid_found = $true
            continue
        }

        $parts = $clean_system -split ','
        $valid_systems += [PSCustomObject]@{
            Hostname = $parts[0].Trim()
            IP = $parts[1].Trim()
        }
    }

    if ($invalid_found) {
        write_status "One or more invalid entries were found in $system_list. Fix the file and run the script again." "red"
        return
    }

    if ($valid_systems.Count -eq 0) {
        write_status "No valid remote systems found in $system_list" "red"
        return
    }

    foreach ($remote_system in $valid_systems) {
        $credential = Get-Credential -Message "Type the credential to login on $($remote_system.Hostname) ($($remote_system.IP))"
        write_status "`nProcessing remote system: $($remote_system.Hostname) ($($remote_system.IP))" "cyan"
        open_remote_session -hostname $remote_system.Hostname -ip $remote_system.IP -credential $credential
    }

    if ((Test-Path $log -PathType Leaf) -and ((Get-Item $log).Length -gt 0)) {
        Write-Host "The file '$log' has been created, you should check it!"
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

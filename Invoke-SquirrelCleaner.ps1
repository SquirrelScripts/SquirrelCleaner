<#
.SYNOPSIS
    Quick-and-dirty Windows cache cleaner. The squirrel cleans your stash.

.DESCRIPTION
    Clears user temp + browser caches by default. No admin needed for the
    defaults. System temp and Windows Update cache are opt-in (and need an
    elevated session). Supports -WhatIf and -Confirm.

.EXAMPLE
    .\Invoke-SquirrelCleaner.ps1 -WhatIf
    Shows what would be freed, deletes nothing.

.EXAMPLE
    .\Invoke-SquirrelCleaner.ps1
    Cleans user temp + browser caches.

.EXAMPLE
    .\Invoke-SquirrelCleaner.ps1 -IncludeSystem -IncludeWindowsUpdate -EmptyRecycleBin
    The works. Run elevated.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$IncludeSystem,
    [switch]$IncludeWindowsUpdate,
    [switch]$SkipBrowsers,
    [switch]$EmptyRecycleBin
)

# ---------------------------------------------------------------- helpers ----
function Format-Bytes {
    param([double]$Bytes)
    if     ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0} KB' -f ($Bytes / 1KB) }
    else                    { "$([int]$Bytes) B" }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeChildren {
    <# Recurse like Get-ChildItem -Recurse, but never descend into (or emit)
       junctions/symlinks. A reparse point dropped in %TEMP% by an installer
       could otherwise aim the delete loop at real data elsewhere on disk. #>
    param(
        [string]$Root,
        [switch]$Directories   # emit directories instead of files
    )
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
    if (-not $rootItem -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) {
                $stack.Push($item.FullName)
                if ($Directories) { $item }
            }
            elseif (-not $Directories) { $item }
        }
    }
}

# running tallies (script scope so Clear-Target can update them)
$script:WouldFree    = 0
$script:Freed        = 0
$script:SkippedFiles = 0
$script:SkippedBytes = 0
$script:Report       = [ordered]@{}
$script:TargetIdx    = 0
$script:TargetCount = 0

function Clear-Target {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name,
        [string[]]$Paths
    )

    # one enumeration: gather every cache file under these paths (junction-safe)
    $files = foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) {
            Get-SafeChildren -Root $p
        }
    }
    if (-not $files) { return }

    $total = @($files).Count
    $size  = ($files | Measure-Object -Property Length -Sum).Sum
    $script:WouldFree += $size

    # outer bar: % of targets completed so far
    $outerPct = [int](($script:TargetIdx - 1) / [Math]::Max($script:TargetCount, 1) * 100)
    Write-Progress -Id 0 -Activity 'SquirrelCleaner' `
        -Status "[$script:TargetIdx/$script:TargetCount]  $Name  —  $(Format-Bytes $size)" `
        -PercentComplete $outerPct

    if ($PSCmdlet.ShouldProcess("$Name ($(Format-Bytes $size))", 'Clear cache')) {
        $got  = 0
        $done = 0
        foreach ($f in $files) {
            $done++
            # update inner bar every 50 files to avoid per-file overhead
            if ($done % 50 -eq 0 -or $done -eq $total) {
                Write-Progress -Id 1 -ParentId 0 -Activity "Deleting: $Name" `
                    -Status "$done / $total files" `
                    -PercentComplete ([int]($done / $total * 100))
            }
            try   { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $got += $f.Length }
            catch {
                # locked/in-use file — skip, but keep the receipts
                $script:SkippedFiles++
                $script:SkippedBytes += $f.Length
                Write-Verbose "Skipped (locked/in-use): $($f.FullName)"
            }
        }
        Write-Progress -Id 1 -Activity 'SquirrelCleaner' -Completed

        # sweep up now-empty folders, deepest first.
        # Directory.Delete($false) removes only if empty and throws (not prompts)
        # otherwise — so non-empty cache dirs get skipped silently, no Y/N nag.
        foreach ($p in $Paths) {
            if (Test-Path -LiteralPath $p) {
                Get-SafeChildren -Root $p -Directories |
                    Sort-Object { $_.FullName.Length } -Descending |
                    ForEach-Object {
                        try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { }
                    }
            }
        }
        $script:Freed += $got
        $script:Report[$Name] = $got
    }
    else {
        $script:Report[$Name] = $size   # -WhatIf: report what we'd reclaim
    }
}

# ------------------------------------------------------------------ banner ----
# 🐿️ only struts on PS 7+ — Windows PowerShell 5.1's conhost renders him as tofu
$ShowMascot = $PSVersionTable.PSVersion.Major -ge 7
$Mascot     = if ($ShowMascot) { '🐿️  ' } else { '' }    # banner prefix
$MascotEnd  = if ($ShowMascot) { '  🐿️' } else { '' }    # summary suffix

Write-Host ""
Write-Host "  ${Mascot}SquirrelScripts — Cache Cleaner" -ForegroundColor DarkYellow
Write-Host "  -----------------------------------" -ForegroundColor DarkGray

# admin-only switches need an elevated session
if (($IncludeSystem -or $IncludeWindowsUpdate) -and -not (Test-IsAdmin)) {
    Write-Warning "System / Windows Update cleanup needs admin. Skipping those — re-run elevated to include them."
    $IncludeSystem = $false
    $IncludeWindowsUpdate = $false
}

# ----------------------------------------- pre-define browser data & count ----
# Defined here (not inside the browser block) so the pre-count below can use them.
$chromium = @(
    [pscustomobject]@{ Name = 'Chrome';  Process = 'chrome';  Root = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
    [pscustomobject]@{ Name = 'Edge';    Process = 'msedge';  Root = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
    [pscustomobject]@{ Name = 'Brave';   Process = 'brave';   Root = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
    [pscustomobject]@{ Name = 'Vivaldi'; Process = 'vivaldi'; Root = "$env:LOCALAPPDATA\Vivaldi\User Data" }
)
$cacheSubs = 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage'
$ffRoot    = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"

# Count how many targets will actually run so Write-Progress can show real %
$script:TargetCount = 2   # user temp + internet cache (always)
if (-not $SkipBrowsers) {
    foreach ($b in $chromium) { if (Test-Path -LiteralPath $b.Root) { $script:TargetCount++ } }
    if (Test-Path -LiteralPath $ffRoot) { $script:TargetCount++ }
}
if ($IncludeSystem)        { $script:TargetCount++ }
if ($IncludeWindowsUpdate) { $script:TargetCount++ }

# -------------------------------------------------------------- user caches ----
$script:TargetIdx++; Clear-Target -Name 'User temp'      -Paths @($env:TEMP)
$script:TargetIdx++; Clear-Target -Name 'Internet cache' -Paths @("$env:LOCALAPPDATA\Microsoft\Windows\INetCache")

# ----------------------------------------------------------- browser caches ----
if (-not $SkipBrowsers) {

    # Chromium family — same layout, so it's a table, not 500 lines of copy-paste.
    # Add a browser = add a line.
    foreach ($b in $chromium) {
        if (-not (Test-Path -LiteralPath $b.Root)) { continue }
        if (Get-Process -Name $b.Process -ErrorAction SilentlyContinue) {
            Write-Warning "$($b.Name) is running — close it for a deeper clean (open files get skipped)."
        }
        # hit every profile, not just Default
        $profiles = Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
        $paths = foreach ($pr in $profiles) {
            foreach ($s in $cacheSubs) { Join-Path $pr.FullName $s }
        }
        $script:TargetIdx++
        Clear-Target -Name "$($b.Name) cache" -Paths $paths
    }

    # Firefox does its own thing
    if (Test-Path -LiteralPath $ffRoot) {
        if (Get-Process -Name 'firefox' -ErrorAction SilentlyContinue) {
            Write-Warning "Firefox is running — close it for a deeper clean."
        }
        $paths = Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'cache2' }
        $script:TargetIdx++
        Clear-Target -Name 'Firefox cache' -Paths $paths
    }
}

# ------------------------------------------------------- system / windows ----
if ($IncludeSystem) {
    $script:TargetIdx++
    Clear-Target -Name 'System temp' -Paths @("$env:WINDIR\Temp")
}

if ($IncludeWindowsUpdate) {
    $wuPath = "$env:WINDIR\SoftwareDistribution\Download"
    $script:TargetIdx++
    # One prompt covers the whole operation: stop service -> clear -> restart.
    # Restart only happens if *we* stopped it, so users who keep wuauserv
    # disabled don't get it resurrected behind their back.
    if ($PSCmdlet.ShouldProcess('Windows Update download cache (wuauserv stopped during clean)', 'Clear')) {
        $wasRunning = (Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue).Status -eq 'Running'
        if ($wasRunning) { Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue }
        Clear-Target -Name 'Windows Update' -Paths @($wuPath) -Confirm:$false
        if ($wasRunning) { Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue }
    }
    else {
        # -WhatIf (or declined): touch nothing, but still report the would-be win
        $size = (Get-SafeChildren -Root $wuPath |
                 Measure-Object -Property Length -Sum).Sum
        if ($size) {
            $script:WouldFree += $size
            $script:Report['Windows Update'] = $size
        }
    }
}

# --------------------------------------------------------------- recycle bin ----
if ($EmptyRecycleBin) {
    if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Empty')) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Host "  Recycle Bin emptied." -ForegroundColor DarkGray
    }
}

# clear progress bars before printing the final report
Write-Progress -Id 1 -Activity 'SquirrelCleaner' -Completed
Write-Progress -Id 0 -Activity 'SquirrelCleaner' -Completed

# ------------------------------------------------------------------- flush ----
Write-Host ""
foreach ($name in $script:Report.Keys) {
    Write-Host ("  {0,-20} {1,12}" -f $name, (Format-Bytes $script:Report[$name]))
}
Write-Host "  --------------------------------" -ForegroundColor DarkGray

if ($WhatIfPreference) {
    Write-Host ("  Would free {0}{1}" -f (Format-Bytes $script:WouldFree), $MascotEnd) -ForegroundColor Yellow
    Write-Host "  (run again without -WhatIf to actually clean)" -ForegroundColor DarkGray
}
else {
    Write-Host ("  Freed {0}{1}" -f (Format-Bytes $script:Freed), $MascotEnd) -ForegroundColor Green
    if ($script:SkippedFiles -gt 0) {
        Write-Host ("  Skipped {0} locked/in-use file{1} ({2}) — rerun after closing apps to grab more" -f `
            $script:SkippedFiles,
            $(if ($script:SkippedFiles -eq 1) { '' } else { 's' }),
            (Format-Bytes $script:SkippedBytes)) -ForegroundColor DarkGray
    }
}
Write-Host ""

# Install YouNeeK Death Terminal from the main branch on Windows.
# No administrator rights. x64 and ARM64.
#
#   irm https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.ps1 | iex
#
# Re-run that command to update. Uninstall (also no administrator):
#
#   $env:DEATHTERMINAL_UNINSTALL='1'; irm https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.ps1 | iex
#
# Or, once the file is on disk:
#
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# Zig 0.13.0 is downloaded into %LOCALAPPDATA%\DeathTerminal\zig when zig 0.13
# is not already on PATH. The executable is installed to
# %LOCALAPPDATA%\DeathTerminal\bin\deathterminal.exe.

#Requires -Version 5.1

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Fail {
    param([string]$Message)
    Write-Host "error: $Message" -ForegroundColor Red
    throw $Message
}

function Test-WindowsOs {
    return ($env:OS -eq 'Windows_NT')
}

function Get-NativeArch {
    $arch = $null
    try {
        $arch = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    } catch {
        $arch = $null
    }
    if (-not $arch -and $env:PROCESSOR_ARCHITEW6432) {
        $arch = $env:PROCESSOR_ARCHITEW6432
    }
    if (-not $arch) {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }
    if (-not $arch) {
        Fail "Could not detect the processor architecture. This installer supports x64 and ARM64 and does not need administrator rights."
    }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'X64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default {
            Fail "Unsupported processor architecture '$arch'. install.ps1 supports x64 and ARM64 only. It does not need administrator rights."
        }
    }
}

function Get-ZigAsset {
    param([string]$Kind)
    # Unary comma so Windows PowerShell 5.1 returns the hashtable instead of its entries.
    if ($Kind -eq 'x64') {
        return ,@{
            Triple = 'x86_64'
            Target = 'x86_64-windows'
            Sha256 = 'd859994725ef9402381e557c60bb57497215682e355204d754ee3df75ee3c158'
        }
    }
    if ($Kind -eq 'arm64') {
        return ,@{
            Triple = 'aarch64'
            Target = 'aarch64-windows'
            Sha256 = '95ff88427af7ba2b4f312f45d2377ce7a033e5e3c620c8caaa396a9aba20efda'
        }
    }
    Fail "No Zig 0.13.0 Windows build for '$Kind'."
}

function Test-Zig013 {
    param([string]$ZigExe)
    if (-not (Test-Path -LiteralPath $ZigExe)) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $ZigExe version 2>&1 | Out-String
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
    $line = $null
    foreach ($part in ($out -split "`r?`n")) {
        if ($part.Trim()) { $line = $part.Trim(); break }
    }
    if (-not $line) { return $false }
    try {
        $v = [version]$line
    } catch {
        return $false
    }
    return ($v.Major -eq 0 -and $v.Minor -eq 13)
}

function Save-Url {
    param([string]$Url, [string]$Dest)
    $partial = "$Dest.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            Write-Step "Downloading $Url"
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 600
            Move-Item -LiteralPath $partial -Destination $Dest -Force
            return
        } catch {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            if ($attempt -ge 3) {
                Fail "Download failed for $Url. $($_.Exception.Message) Check the network connection and run the installer again. No administrator rights are required."
            }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Assert-Sha256 {
    param([string]$Path, [string]$Expected)
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    $want = $Expected.ToLowerInvariant()
    if ($got -ne $want) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Fail "Checksum mismatch for $Path. Expected $want, got $got. The download may be corrupt. Run the installer again."
    }
}

function Convert-RvaToOffset {
    param(
        [byte[]]$Bytes,
        [uint32]$Rva,
        [int]$SectionTable,
        [int]$SectionCount
    )
    $i = 0
    while ($i -lt $SectionCount) {
        $s = $SectionTable + ($i * 40)
        $virtualSize = [BitConverter]::ToUInt32($Bytes, $s + 8)
        $virtualAddress = [BitConverter]::ToUInt32($Bytes, $s + 12)
        $rawSize = [BitConverter]::ToUInt32($Bytes, $s + 16)
        $raw = [BitConverter]::ToUInt32($Bytes, $s + 20)
        $size = $virtualSize
        if ($rawSize -gt $size) { $size = $rawSize }
        if ($size -lt 1) { $size = 1 }
        if ($Rva -ge $virtualAddress -and $Rva -lt ($virtualAddress + $size)) {
            return [int]($raw + ($Rva - $virtualAddress))
        }
        $i++
    }
    Fail ("RVA 0x{0:X} is not inside a section of the executable." -f $Rva)
}

function Get-PeImportDlls {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        Fail "$Path is not a Windows executable (missing MZ header)."
    }
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($pe -lt 0 -or ($pe + 24) -gt $bytes.Length) {
        Fail "$Path has a corrupt PE header."
    }
    if ($bytes[$pe] -ne 0x50 -or $bytes[$pe + 1] -ne 0x45 -or $bytes[$pe + 2] -ne 0 -or $bytes[$pe + 3] -ne 0) {
        Fail "$Path is not a PE file."
    }
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $opt = $pe + 24
    $magic = [BitConverter]::ToUInt16($bytes, $opt)
    if ($magic -eq 0x20B) {
        $dd = $opt + 112
    } elseif ($magic -eq 0x10B) {
        $dd = $opt + 96
    } else {
        Fail ("{0} has an unknown PE optional header (magic 0x{1:X})." -f $Path, $magic)
    }
    if (($dd + 16) -gt $bytes.Length) {
        Fail "$Path PE data directories are truncated."
    }
    $importRva = [BitConverter]::ToUInt32($bytes, $dd + 8)
    if ($importRva -eq 0) { return @() }
    $sectionTable = $opt + $optSize
    $pos = Convert-RvaToOffset -Bytes $bytes -Rva $importRva -SectionTable $sectionTable -SectionCount $sectionCount
    $names = New-Object System.Collections.Generic.List[string]
    while (($pos + 20) -le $bytes.Length) {
        $allZero = $true
        $i = 0
        while ($i -lt 20) {
            if ($bytes[$pos + $i] -ne 0) { $allZero = $false; break }
            $i++
        }
        if ($allZero) { break }
        $nameRva = [BitConverter]::ToUInt32($bytes, $pos + 12)
        $nameOff = Convert-RvaToOffset -Bytes $bytes -Rva $nameRva -SectionTable $sectionTable -SectionCount $sectionCount
        $end = $nameOff
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        $name = [System.Text.Encoding]::ASCII.GetString($bytes, $nameOff, ($end - $nameOff))
        if ($name) { [void]$names.Add($name) }
        $pos += 20
    }
    return @($names.ToArray())
}

function Test-SystemDll {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if ($n.StartsWith('api-ms-win-')) { return $true }
    if ($n.StartsWith('ext-ms-')) { return $true }
    $system = @(
        'kernel32.dll', 'kernelbase.dll', 'user32.dll', 'gdi32.dll', 'gdiplus.dll',
        'shell32.dll', 'ws2_32.dll', 'wsock32.dll', 'ntdll.dll', 'advapi32.dll',
        'ole32.dll', 'oleaut32.dll', 'bcrypt.dll', 'crypt32.dll', 'imm32.dll',
        'comctl32.dll', 'comdlg32.dll', 'dwmapi.dll', 'uxtheme.dll', 'shlwapi.dll',
        'msvcrt.dll', 'ucrtbase.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
        'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'winmm.dll', 'setupapi.dll',
        'version.dll', 'iphlpapi.dll', 'userenv.dll', 'sechost.dll', 'rpcrt4.dll',
        'combase.dll', 'cfgmgr32.dll', 'powrprof.dll', 'profapi.dll', 'bcryptprimitives.dll',
        'shcore.dll', 'oleacc.dll', 'nsi.dll', 'dnsapi.dll', 'msimg32.dll', 'normaliz.dll',
        'wldap32.dll', 'secur32.dll', 'sspicli.dll', 'cryptbase.dll', 'msvcp_win.dll',
        'winspool.drv', 'opengl32.dll', 'dxgi.dll', 'd3d11.dll', 'd3d12.dll', 'dcomp.dll',
        'hid.dll', 'xinput1_4.dll', 'winhttp.dll', 'wininet.dll', 'cabinet.dll',
        'imagehlp.dll', 'dbghelp.dll', 'psapi.dll', 'pdh.dll', 'netapi32.dll',
        'avrt.dll', 'mmdevapi.dll', 'propsys.dll', 'windowscodecs.dll', 'mfplat.dll'
    )
    return ($system -contains $n)
}

function Get-DllIndex {
    param([string[]]$Roots)
    $index = @{}
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -LiteralPath $root -Recurse -Filter *.dll -File -ErrorAction SilentlyContinue
        foreach ($file in @($found)) {
            $key = $file.Name.ToLowerInvariant()
            if (-not $index.ContainsKey($key)) {
                $index[$key] = $file.FullName
            }
        }
    }
    return ,$index
}

function Copy-NeededDlls {
    param(
        [string]$ExePath,
        [string]$BinDir,
        [string]$ZigDir,
        [string]$BuildBin
    )
    $imports = @(Get-PeImportDlls -Path $ExePath)
    $index = Get-DllIndex -Roots @($BuildBin, $ZigDir)
    $copied = New-Object System.Collections.Generic.List[string]
    foreach ($dll in $imports) {
        if (-not $dll) { continue }
        if (Test-SystemDll $dll) { continue }
        $key = $dll.ToLowerInvariant()
        if ($key -eq 'vulkan-1.dll') {
            Write-Step "vulkan-1.dll is not bundled. The graphics driver supplies it. Without it, Death Terminal uses the software renderer."
            continue
        }
        if (-not $index.ContainsKey($key)) {
            Fail "deathterminal.exe needs $dll next to the executable, and the Zig install at $ZigDir does not contain it. Close other copies of Death Terminal and run the installer again."
        }
        $dest = Join-Path $BinDir $dll
        Copy-Item -LiteralPath $index[$key] -Destination $dest -Force
        [void]$copied.Add($dest)
        Write-Step "Installed $dest"
    }
    $beside = @()
    if ($BuildBin -and (Test-Path -LiteralPath $BuildBin)) {
        $beside = @(Get-ChildItem -LiteralPath $BuildBin -Filter *.dll -File -ErrorAction SilentlyContinue)
    }
    foreach ($file in $beside) {
        $dest = Join-Path $BinDir $file.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            [void]$copied.Add($dest)
            Write-Step "Installed $dest"
        }
    }
    if ($copied.Count -eq 0) {
        Write-Step "No extra DLLs to copy. deathterminal.exe uses Windows system libraries. vulkan-1.dll is loaded at run time from the graphics driver when it is present; otherwise the software renderer is used."
    }
    return @($copied.ToArray())
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    $a = $Left.Trim().Trim('"').TrimEnd('\', '/')
    $b = $Right.Trim().Trim('"').TrimEnd('\', '/')
    return $a.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)
}

function Send-EnvironmentChange {
    if (-not ('DeathTerminal.NativeMethods' -as [type])) {
        Add-Type -Namespace DeathTerminal -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, int Msg, System.IntPtr wParam, string lParam, int fuFlags, int uTimeout, out System.IntPtr lpdwResult);
"@
    }
    $result = [IntPtr]::Zero
    [void][DeathTerminal.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
}

function Add-UserPathEntry {
    param([string]$BinDir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
    $already = $false
    foreach ($part in $parts) {
        if (Test-SamePath $part $BinDir) { $already = $true; break }
    }
    if (-not $already) {
        $updated = $BinDir
        if ($userPath.Trim()) {
            $updated = ($userPath.TrimEnd(';') + ';' + $BinDir)
        }
        try {
            [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        } catch {
            Fail "Could not add $BinDir to the user PATH. $($_.Exception.Message) This installer edits the user PATH only (no administrator). Add it yourself with: [Environment]::SetEnvironmentVariable('Path', '$BinDir;' + [Environment]::GetEnvironmentVariable('Path','User'), 'User')"
        }
        Write-Step "Added $BinDir to the user PATH"
    } else {
        Write-Step "User PATH already contains $BinDir"
    }
    if (-not (($env:Path -split ';') | Where-Object { Test-SamePath $_ $BinDir })) {
        $env:Path = $BinDir + ';' + $env:Path
    }
    try {
        Send-EnvironmentChange
    } catch {
        Write-Step "Open a new terminal so the updated user PATH is picked up."
    }
}

function Remove-UserPathEntry {
    param([string]$BinDir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { return }
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = $false
    foreach ($part in @($userPath -split ';')) {
        if (-not $part) { continue }
        if (Test-SamePath $part $BinDir) { $removed = $true; continue }
        [void]$kept.Add($part)
    }
    if (-not $removed) { return }
    $updated = ($kept -join ';')
    try {
        if ($updated) {
            [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        } else {
            [Environment]::SetEnvironmentVariable('Path', $null, 'User')
        }
    } catch {
        Fail "Could not remove $BinDir from the user PATH. $($_.Exception.Message)"
    }
    Write-Step "Removed $BinDir from the user PATH"
    try { Send-EnvironmentChange } catch { }
}

function New-GuiShortcut {
    param([string]$ExePath)
    if (-not $env:APPDATA) {
        Fail "APPDATA is not set, so the Start Menu shortcut cannot be created."
    }
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    if (-not (Test-Path -LiteralPath $programs)) {
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
    }
    $lnk = Join-Path $programs 'YouNeeK Death Terminal.lnk'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk)
        $shortcut.TargetPath = $ExePath
        $shortcut.Arguments = '--gui'
        $shortcut.WorkingDirectory = $env:USERPROFILE
        $shortcut.WindowStyle = 1
        $shortcut.Description = 'YouNeeK Death Terminal'
        $shortcut.IconLocation = "$ExePath,0"
        $shortcut.Save()
    } catch {
        Fail "Could not create the Start Menu shortcut at $lnk. $($_.Exception.Message) The program is installed at $ExePath. Run it with: `"$ExePath`" --gui"
    }
    Write-Step "Start Menu shortcut runs --gui: $lnk"
    return $lnk
}

function Install-DeathTerminal {
    if (-not $env:LOCALAPPDATA) {
        Fail "LOCALAPPDATA is not set. This installer uses %LOCALAPPDATA%\DeathTerminal and does not need administrator rights."
    }
    $root = Join-Path $env:LOCALAPPDATA 'DeathTerminal'
    $bin = Join-Path $root 'bin'
    $exe = Join-Path $bin 'deathterminal.exe'
    $kind = Get-NativeArch
    $asset = Get-ZigAsset -Kind $kind
    if (Test-Path -LiteralPath $exe) {
        Write-Step "Updating YouNeeK Death Terminal ($kind)"
    } else {
        Write-Step "Installing YouNeeK Death Terminal ($kind)"
    }
    Write-Step "Install prefix (no administrator rights): $root"

    $zigExe = $null
    $cmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Zig013 $cmd.Source)) {
        $zigExe = $cmd.Source
        Write-Step "Using Zig 0.13 at $zigExe"
    }
    $bundledZig = Join-Path $root 'zig\zig.exe'
    if (-not $zigExe -and (Test-Zig013 $bundledZig)) {
        $zigExe = $bundledZig
        Write-Step "Using Zig 0.13 at $zigExe"
    }
    if (-not $zigExe) {
        $zipName = "zig-windows-$($asset.Triple)-0.13.0.zip"
        $zipUrl = "https://ziglang.org/download/0.13.0/$zipName"
        $downloads = Join-Path $root 'downloads'
        New-Item -ItemType Directory -Path $downloads -Force | Out-Null
        $zipPath = Join-Path $downloads $zipName
        Write-Step "Zig 0.13 not found. Downloading portable Zig 0.13.0 for $($asset.Triple) into $root\zig"
        $need = $true
        if (Test-Path -LiteralPath $zipPath) {
            $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
            if ($have -eq $asset.Sha256) { $need = $false; Write-Step "Using cached $zipPath" }
        }
        if ($need) {
            Save-Url -Url $zipUrl -Dest $zipPath
            Assert-Sha256 -Path $zipPath -Expected $asset.Sha256
        }
        $extract = Join-Path $root 'zig-extract'
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
        $found = Get-ChildItem -LiteralPath $extract -Recurse -Filter zig.exe -File | Select-Object -First 1
        if (-not $found) {
            Fail "The Zig zip did not contain zig.exe. Run the installer again."
        }
        $zigHome = Join-Path $root 'zig'
        if (Test-Path -LiteralPath $zigHome) { Remove-Item -LiteralPath $zigHome -Recurse -Force }
        New-Item -ItemType Directory -Path $zigHome -Force | Out-Null
        $bundle = $found.Directory.FullName
        Copy-Item -Path (Join-Path $bundle '*') -Destination $zigHome -Recurse -Force
        $zigExe = Join-Path $zigHome 'zig.exe'
        if (-not (Test-Zig013 $zigExe)) {
            Fail "Extracted Zig at $zigExe does not report version 0.13.x."
        }
        Write-Step "Installed Zig 0.13.0 to $zigHome"
    }

    $sourceUrl = 'https://codeload.github.com/AndrewGrayYouNeeK/Death-terminal-/zip/refs/heads/main'
    $downloads = Join-Path $root 'downloads'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    $sourceZip = Join-Path $downloads 'deathterminal-main.zip'
    Write-Step "Downloading the main branch source zip"
    Save-Url -Url $sourceUrl -Dest $sourceZip
    $srcParent = Join-Path $root 'src'
    if (Test-Path -LiteralPath $srcParent) { Remove-Item -LiteralPath $srcParent -Recurse -Force }
    New-Item -ItemType Directory -Path $srcParent -Force | Out-Null
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $srcParent -Force
    $src = $srcParent
    if (-not (Test-Path -LiteralPath (Join-Path $src 'build.zig'))) {
        $kids = @(Get-ChildItem -LiteralPath $srcParent -Directory)
        if ($kids.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $kids[0].FullName 'build.zig'))) {
            $src = $kids[0].FullName
        } else {
            Fail "The main source zip did not contain build.zig."
        }
    }

    $cache = Join-Path $root 'cache'
    $gcache = Join-Path $root 'global-cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    New-Item -ItemType Directory -Path $gcache -Force | Out-Null
    $log = Join-Path $root 'build.log'
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $target = $asset.Target
    Write-Step "Building: $zigExe build -Doptimize=ReleaseSafe -Dtarget=$target"
    $prev = Get-Location
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Set-Location -LiteralPath $src
        & $zigExe build -Doptimize=ReleaseSafe "-Dtarget=$target" --cache-dir $cache --global-cache-dir $gcache 2>&1 | ForEach-Object {
            $text = "$_"
            Write-Host $text
            Add-Content -LiteralPath $log -Value $text -Encoding UTF8
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        Set-Location $prev
    }
    $built = Join-Path $src 'zig-out\bin\deathterminal.exe'
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $built)) {
        Write-Host "error: the Windows build failed (exit $code)." -ForegroundColor Red
        Write-Host "The Windows build compiles FreeType and HarfBuzz from source. Zig downloads them on the first build, so this machine needs network access to github.com and ziglang.org."
        Write-Host "No administrator rights are required. The log is $log."
        if (Test-Path -LiteralPath $log) {
            Write-Host "Last lines:"
            Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Host $_ }
        }
        throw "zig build -Doptimize=ReleaseSafe -Dtarget=$target failed"
    }

    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $installedExe = Join-Path $bin 'deathterminal.exe'
    Copy-Item -LiteralPath $built -Destination $installedExe -Force
    Write-Step "Installed $installedExe"
    $zigHome = Split-Path -Parent $zigExe
    [void](Copy-NeededDlls -ExePath $installedExe -BinDir $bin -ZigDir $zigHome -BuildBin (Split-Path -Parent $built))
    Add-UserPathEntry -BinDir $bin
    [void](New-GuiShortcut -ExePath $installedExe)

    Write-Host ""
    Write-Step "Installed $installedExe"
    Write-Host ""
    Write-Host "This window can run:"
    Write-Host ""
    Write-Host "  deathterminal --gui"
    Write-Host ""
    Write-Host "Or open `"YouNeeK Death Terminal`" from the Start Menu (that shortcut passes --gui)."
    Write-Host "Open a new terminal if deathterminal is not found yet."
    Write-Host "Run the same install command again to update."
    Write-Host "Uninstall (no administrator prompt):"
    Write-Host ""
    Write-Host "  `$env:DEATHTERMINAL_UNINSTALL='1'; irm https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.ps1 | iex"
    Write-Host ""
}

function Uninstall-DeathTerminal {
    if (-not $env:LOCALAPPDATA) {
        Fail "LOCALAPPDATA is not set."
    }
    $root = Join-Path $env:LOCALAPPDATA 'DeathTerminal'
    $bin = Join-Path $root 'bin'
    Write-Step "Uninstalling YouNeeK Death Terminal"
    if ($env:APPDATA) {
        $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\YouNeeK Death Terminal.lnk'
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Step "Removed $lnk"
        }
    }
    Remove-UserPathEntry -BinDir $bin
    if (Test-Path -LiteralPath $root) {
        try {
            Remove-Item -LiteralPath $root -Recurse -Force
            Write-Step "Removed $root"
        } catch {
            Fail "Could not remove $root. $($_.Exception.Message) Close Death Terminal and run the uninstall again."
        }
    } else {
        Write-Step "No install directory at $root"
    }
    Write-Step "Left %APPDATA%\death-terminal in place."
}

function Main {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
    }
    if (-not (Test-WindowsOs)) {
        Fail "install.ps1 is for Windows. On macOS or Linux run: curl -fsSL https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.sh | sh"
    }
    $uninstall = $false
    if ($env:DEATHTERMINAL_UNINSTALL -eq '1') { $uninstall = $true }
    foreach ($arg in @($args)) {
        if ($arg -eq '-Uninstall' -or $arg -eq '--uninstall' -or $arg -eq 'uninstall') {
            $uninstall = $true
        }
    }
    if ($uninstall) {
        Uninstall-DeathTerminal
    } else {
        Install-DeathTerminal
    }
}

if ($env:DEATHTERMINAL_INSTALL_LIB -ne '1') {
    Main @args
}

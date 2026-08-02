<#
.SYNOPSIS
  Build a minc UEFI example and boot it under QEMU + OVMF.

.DESCRIPTION
  ./run.ps1                                  # list the examples and how to run one
  ./run.ps1 uefi/01_hello.mc                 # build + boot (all output in the QEMU window)
  ./run.ps1 kernel/03_lapic_timer.mc
  ./run.ps1 uefi/01_hello.mc -BuildOnly      # just produce build/01_hello.efi
  ./run.ps1 kernel/02_traps.mc -Headless -Expect "CPU EXCEPTION"

  The minc compiler is found via the MINC environment variable (install
  dir, or a direct binary path), then as `minc` on PATH. QEMU + OVMF are found via MINC_QEMU / MINC_OVMF_CODE /
  MINC_OVMF_VARS, or under C:\msys64 / C:\msys2
  (pacman -S mingw-w64-x86_64-qemu).

  minc emits VEX/AVX encodings, so the vCPU must expose AVX (-Cpu max by
  default; QEMU's plain qemu64 model does not).
#>
param(
    [Parameter(Position = 0)]
    [string]$App = "",
    [switch]$BuildOnly,
    [switch]$Headless,
    [string]$Expect = "",
    [int]$TimeoutSec = 20,
    [string]$Cpu = "max",
    [int]$Smp = 1,
    [int]$MemMB = 256
)

$ErrorActionPreference = "Stop"
$Root  = $PSScriptRoot
$Build = Join-Path $Root "build"

function Fail($m) { Write-Host $m -ForegroundColor Red; exit 1 }
function Step($m) { Write-Host ">> $m" -ForegroundColor Cyan }

# OVMF mirrors its console to the serial port with escape sequences included
# (ESC[2J, ESC[=3h, ...). Those target a terminal emulator inside QEMU. Replayed
# into this shell they clear the screen and change its mode.
function Strip-Ansi([string]$s) {
    $esc = [char]27
    return ($s -replace "$esc\[[0-9;=?]*[A-Za-z]", "")
}

# With no example, list what is available and which one to start with, instead
# of prompting for a parameter name the reader has not seen yet.
function Show-Usage {
    Write-Host ""
    Write-Host "minc on UEFI x64 - compile an example and boot it under QEMU + OVMF."
    Write-Host ""
    Write-Host "  ./run.ps1 uefi/01_hello.mc" -ForegroundColor Green -NoNewline
    Write-Host "   <- start here: a whole UEFI app in one file"
    Write-Host ""
    $blurb = @{
        "uefi"   = "on the firmware: console, graphics, memory map, files"
        "kernel" = "after ExitBootServices: the bare hardware, on a console of their own"
    }
    foreach ($dir in @("uefi", "kernel")) {
        $items = @(Get-ChildItem (Join-Path $Root $dir) -Filter *.mc -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($items.Count -eq 0) { continue }
        Write-Host "$dir/" -ForegroundColor Cyan -NoNewline
        Write-Host "  $($blurb[$dir])"
        foreach ($f in $items) { Write-Host "  ./run.ps1 $dir/$($f.Name)" }
        Write-Host ""
    }
    Write-Host "options" -ForegroundColor Cyan
    Write-Host "  -BuildOnly                  compile to build/<name>.efi, do not boot"
    Write-Host "  -Headless [-Expect ""text""]  no window: print the serial log, check it for 'text'"
    Write-Host "  -Smp 4                      CPU count (default 1, or 4 for multi-core examples)"
    Write-Host "  -TimeoutSec 20  -Cpu max  -MemMB 256"
    Write-Host ""
}

function Find-Minc {
    if ($env:MINC -and (Test-Path $env:MINC)) {
        if (Test-Path $env:MINC -PathType Container) { return (Join-Path $env:MINC "minc.exe") }
        return $env:MINC
    }
    $cmd = Get-Command minc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail "minc not found. Set MINC to the install dir or put minc on PATH."
}

function Find-Qemu {
    if ($env:MINC_QEMU -and $env:MINC_OVMF_CODE -and $env:MINC_OVMF_VARS -and (Test-Path $env:MINC_QEMU)) {
        return @($env:MINC_QEMU, $env:MINC_OVMF_CODE, $env:MINC_OVMF_VARS)
    }
    foreach ($r in @("C:\msys64", "C:\msys2")) {
        $q    = "$r\mingw64\bin\qemu-system-x86_64.exe"
        $code = "$r\mingw64\share\qemu\edk2-x86_64-code.fd"
        $vars = "$r\mingw64\share\qemu\edk2-i386-vars.fd"
        if ((Test-Path $q) -and (Test-Path $code) -and (Test-Path $vars)) { return @($q, $code, $vars) }
    }
    Fail "qemu/OVMF not found. Install: pacman -S mingw-w64-x86_64-qemu, or set MINC_QEMU / MINC_OVMF_CODE / MINC_OVMF_VARS."
}

# show-tabs draws the console tab bar in the QEMU window, so the VGA and serial0
# consoles are one click apart instead of Ctrl+Alt+<n>. Only the gtk display
# supports it. Without gtk, fall back to QEMU's default display.
function Get-DisplayArgs {
    $displays = & $Qemu -display help 2>&1 | Out-String
    if ($displays -match "(?m)^\s*gtk\s*$") { return @("-display", "gtk,show-tabs=on") }
    return @()
}

if (-not $App) { Show-Usage; exit 0 }

$Minc = Find-Minc
if (!(Test-Path $App)) { $App = Join-Path $Root $App }
if (!(Test-Path $App)) { Fail "example not found: $App" }
$App = (Resolve-Path $App).Path
$appBase = [IO.Path]::GetFileNameWithoutExtension($App)
# kernel/ examples capture the framebuffer before ExitBootServices and draw
# their own console on it, mirrored to COM1. Both need the VGA device present.
$isKernel = (Split-Path -Leaf (Split-Path -Parent $App)) -eq "kernel"

# Examples about more than one CPU boot with four by default, since one core
# tells the reader nothing. An explicit -Smp still wins. Everything else stays
# single-core.
$MultiCore = @("10_cpus")
if (-not $PSBoundParameters.ContainsKey('Smp') -and ($MultiCore -contains $appBase)) {
    $Smp = 4
}

New-Item -ItemType Directory -Force $Build | Out-Null
$efi = Join-Path $Build "$appBase.efi"

# Compile with cwd = the repo root so `import x;` resolves lib/x.mc.
Step "compiling $App"
Push-Location $Root
try { & $Minc $App --target uefi-x64 -o $efi } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { Fail "compile failed" }
if ($BuildOnly) { Step "built $efi"; exit 0 }

# A virtual-FAT ESP: QEMU serves this directory as the boot disk.
$esp = Join-Path $Build "esp"
New-Item -ItemType Directory -Force (Join-Path $esp "EFI\BOOT") | Out-Null
Copy-Item $efi (Join-Path $esp "EFI\BOOT\BOOTX64.EFI") -Force

$qi = Find-Qemu; $Qemu = $qi[0]; $OvmfCode = $qi[1]; $OvmfVars = $qi[2]
$varsRw = Join-Path $Build "uefi_vars.fd"   # OVMF needs a writable NVRAM store
Copy-Item $OvmfVars $varsRw -Force

# A relative fat:rw: path, resolved from QEMU's working directory of $Root,
# keeps the drive-letter colon out of the option syntax.
$base = @(
    "-machine", "q35", "-cpu", $Cpu, "-smp", "$Smp", "-m", "${MemMB}M",
    "-drive", "if=pflash,format=raw,readonly=on,file=$OvmfCode",
    "-drive", "if=pflash,format=raw,file=$varsRw",
    "-drive", "format=raw,file=fat:rw:build/esp",
    "-net", "none")

if ($Headless) {
    $log = Join-Path $Build "serial.log"
    if (Test-Path $log) { Remove-Item $log -Force }
    $qargs = $base + @("-display", "none", "-serial", "file:$log")
    Step "qemu headless (${TimeoutSec}s timeout)"
    $p = Start-Process -FilePath $Qemu -ArgumentList $qargs -PassThru -WindowStyle Hidden -WorkingDirectory $Root
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        if ($Expect -and (Test-Path $log) -and ((Strip-Ansi (Get-Content $log -Raw)) -match [regex]::Escape($Expect))) { break }
        Start-Sleep -Milliseconds 400
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    # The log keeps the raw bytes. What is matched and printed is escape-free,
    # so a stray sequence cannot split a match or reach this terminal.
    $serial = if (Test-Path $log) { Strip-Ansi (Get-Content $log -Raw) } else { "" }
    Write-Host "--- serial console ---"
    Write-Host $serial
    if ($Expect) {
        if ($serial -match [regex]::Escape($Expect)) {
            Write-Host "MATCH: '$Expect'" -ForegroundColor Green; exit 0
        }
        Fail "MISSING expected output: '$Expect'"
    }
}
else {
    # No -serial. QEMU's graphical default is `vc`, a terminal rendered inside
    # the QEMU window. Nothing else writes to it.
    #
    # Turn off every other `vc` default, since each adds a tab in front of the
    # example's output. -parallel none drops the LPT console and -monitor none
    # drops the QEMU monitor, the "compat_monitor0" tab.
    $qargs = $base + (Get-DisplayArgs) + @("-parallel", "none", "-monitor", "none")
    if ($isKernel) {
        # The window opens on the VGA tab, where a kernel example draws its
        # console. The serial0 tab carries the same text. Keystrokes reach the
        # PS/2 keyboard from the VGA tab and COM1 from the serial tab, and
        # con_getc reads either one.
        Step "qemu (the VGA tab is the kernel's console; close the window to exit)"
    }
    else {
        Step "qemu (VGA and serial0 tabs in the window; close it to exit)"
    }
    Push-Location $Root
    try { & $Qemu @qargs } finally { Pop-Location }
}

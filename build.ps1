<#
    build.ps1 - assemble a Channel F ROM and optionally launch it in MAME.

    Examples:
        .\build.ps1                     assemble src\bufo.asm
        .\build.ps1 -Src test_bands     assemble a different source
        .\build.ps1 -Run                assemble and launch MAME interactively
        .\build.ps1 -Shot               assemble, run 4 s headless, snapshot
        .\build.ps1 -Shot -Seconds 10   snapshot after 10 emulated seconds

    The MAME executable is taken from -Mame, or from the MAME environment
    variable, or from a local default. Set $env:MAME to point at your own.
#>
param(
    [string]$Src = "bufo",
    [switch]$Run,
    [switch]$Shot,
    [int]$Seconds = 4,
    [string]$Mame = $(if ($env:MAME) { $env:MAME } else { "J:\users\utente\Downloads\mame.exe" })
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dasm = Join-Path $root "tools\dasm\bin\dasm.exe"
$roms = Join-Path $root "emu\roms"
$bin  = Join-Path $root "build\$Src.bin"

New-Item -ItemType Directory -Force -Path (Join-Path $root "build") | Out-Null

# ---- assembly -----------------------------------------------------
$out = & $dasm (Join-Path $root "src\$Src.asm") `
    "-I$(Join-Path $root 'src')" `
    -f3 `
    "-o$bin" `
    "-l$(Join-Path $root "build\$Src.lst")" 2>&1
$out | ForEach-Object { Write-Output $_ }
if ($LASTEXITCODE -ne 0) { throw "dasm returned $LASTEXITCODE" }

# ---- branch verification ------------------------------------------
# F8 relative branches carry a displacement of one signed byte. If the
# label is more than +-127 bytes away, dasm TRUNCATES the value and says
# nothing: the program jumps somewhere arbitrary and the symptoms look
# like bugs in the assembly. This actually happened (a "bnz" meant to
# loop back landed inside another routine, and the game drew a band of
# random pixels). From here on the build stops first.
& python (Join-Path $root "tools\brcheck.py") (Join-Path $root "build\$Src.lst")
if ($LASTEXITCODE -ne 0) { throw "branch out of range (see above)" }

$size = (Get-Item $bin).Length
Write-Output ("OK  {0}  {1} bytes ({2:N1} KiB)" -f $bin, $size, ($size / 1024))

# ---- execution ----------------------------------------------------
if ($Run) {
    & $Mame channelf -rompath $roms -cart $bin -window -skip_gameinfo
}
elseif ($Shot) {
    $shots = Join-Path $root "shots"
    Remove-Item -Recurse -Force (Join-Path $shots "channelf") -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $shots | Out-Null
    & $Mame channelf -rompath $roms -cart $bin `
        -seconds_to_run $Seconds -snapshot_directory $shots `
        -window -sound none -nothrottle -skip_gameinfo 2>&1 |
        Where-Object { $_ -notmatch "falling back to auto" } |
        ForEach-Object { Write-Output $_ }
    # note: do NOT name this variable $shot - it collides with [switch]$Shot
    $snap = Get-ChildItem -Path (Join-Path $shots "channelf") -Filter "*.png" -Recurse |
            Sort-Object Name | Select-Object -Last 1
    if ($snap) {
        Write-Output "snapshot: $($snap.FullName)"
        & python (Join-Path $root "tools\vcheck.py") $snap.FullName
    }
}

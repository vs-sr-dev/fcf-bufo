<#
    build.ps1 - assembla una ROM Channel F e opzionalmente la lancia in MAME.

    Esempi:
        .\build.ps1                     assembla src\bufo.asm
        .\build.ps1 -Src test_bands     assembla un altro sorgente
        .\build.ps1 -Run                assembla e lancia MAME interattivo
        .\build.ps1 -Shot               assembla, esegue 4s headless, snapshot
        .\build.ps1 -Shot -Seconds 10   snapshot dopo 10 secondi emulati
#>
param(
    [string]$Src = "bufo",
    [switch]$Run,
    [switch]$Shot,
    [int]$Seconds = 4,
    [string]$Mame = "J:\users\utente\Downloads\mame.exe"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dasm = Join-Path $root "tools\dasm\bin\dasm.exe"
$roms = Join-Path $root "emu\roms"
$bin  = Join-Path $root "build\$Src.bin"

New-Item -ItemType Directory -Force -Path (Join-Path $root "build") | Out-Null

# ---- assemblaggio -------------------------------------------------
$out = & $dasm (Join-Path $root "src\$Src.asm") `
    "-I$(Join-Path $root 'src')" `
    -f3 `
    "-o$bin" `
    "-l$(Join-Path $root "build\$Src.lst")" 2>&1
$out | ForEach-Object { Write-Output $_ }
if ($LASTEXITCODE -ne 0) { throw "dasm ha restituito $LASTEXITCODE" }

# ---- verifica dei branch ------------------------------------------
# I branch relativi della F8 hanno uno spostamento di un solo byte con
# segno. Se l'etichetta e' oltre +-127 byte, dasm TRONCA il valore e non
# segnala nulla: il programma salta in un punto arbitrario e i sintomi
# sembrano bug del codice assembly. E' successo davvero (un "bnz" di
# ritorno atterrava dentro un'altra routine, e il gioco disegnava una
# banda di pixel casuali). Da qui in poi la build si ferma prima.
& python (Join-Path $root "tools\brcheck.py") (Join-Path $root "build\$Src.lst")
if ($LASTEXITCODE -ne 0) { throw "branch fuori portata (vedi sopra)" }

$size = (Get-Item $bin).Length
Write-Output ("OK  {0}  {1} byte ({2:N1} KiB)" -f $bin, $size, ($size / 1024))

# ---- esecuzione ---------------------------------------------------
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
    # nota: non chiamare questa variabile $shot - collide con [switch]$Shot
    $snap = Get-ChildItem -Path (Join-Path $shots "channelf") -Filter "*.png" -Recurse |
            Sort-Object Name | Select-Object -Last 1
    if ($snap) {
        Write-Output "snapshot: $($snap.FullName)"
        & python (Join-Path $root "tools\vcheck.py") $snap.FullName
    }
}

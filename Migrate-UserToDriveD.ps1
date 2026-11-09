#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Безопасный перенос профиля пользователя с диска C: на диск D: (через junction-ссылки).

.DESCRIPTION
    Что делает:
      1. Копирует Downloads, Documents, Videos, Pictures, Music, Desktop и подпапки AppData\Local / Roaming на D:.
      2. Проверяет, что копия полностью совпадает с оригиналом.
      3. Только после этого заменяет оригинал на C: junction-ссылкой на D:.
      4. Обновляет пути в реестре (только для успешно перенесённых библиотек) и перезапускает Проводник.

    Отличия от простых скриптов:
      - ничего не удаляется, пока копия не проверена (код robocopy + повторное сравнение);
      - сохраняются права доступа (ACL) и владелец;
      - режим -DryRun (ничего не меняет, только показывает план);
      - проверки: D: существует и NTFS, хватает места, источник и назначение не совпадают,
        пользователь = текущий (чтобы HKCU указывал на нужного пользователя);
      - предупреждение о запущенных программах, подтверждение перед стартом;
      - резервная копия ветки реестра и подробные логи в %ProgramData%\ProfileMigration;
      - папки в OneDrive пропускаются; скрипт можно безопасно запускать повторно.

.PARAMETER TargetUser
    Имя папки профиля. По умолчанию — текущий пользователь (единственный допустимый вариант).
.PARAMETER DestRoot
    Корень назначения. По умолчанию D:\Users.
.PARAMETER DryRun
    Только показать, что будет сделано.
.PARAMETER SkipAppData
    Не трогать AppData (самая рискованная часть).
.PARAMETER KeepOldCopy
    Не удалять оригиналы на C:, а оставить как <папка>.migrated_old (удалите вручную после проверки).
.PARAMETER NoExplorerRestart
    Не перезапускать Проводник.
.PARAMETER Yes
    Не задавать вопросы подтверждения.

.EXAMPLE
    .\Migrate-UserToDriveD.ps1 -DryRun
    .\Migrate-UserToDriveD.ps1 -KeepOldCopy
#>
[CmdletBinding()]
param(
    [string]$TargetUser,
    [string]$DestRoot = 'D:\Users',
    [switch]$DryRun,
    [switch]$SkipAppData,
    [switch]$KeepOldCopy,
    [switch]$NoExplorerRestart,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------
# Настройки
# ---------------------------------------------------------------------
$UsfKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$UsfKeyReg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

$Libraries = @(
    @{ Name = 'Downloads'; Reg = @('{374DE290-123F-4565-9164-39C4925E467B}', '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}') },
    @{ Name = 'Documents'; Reg = @('Personal', '{F42EE2D3-909F-4907-8871-4C22FC0BF756}') },
    @{ Name = 'Videos';    Reg = @('My Video', '{35286161-5079-4140-BA5D-1BF21823487A}') },
    @{ Name = 'Pictures';  Reg = @('My Pictures', '{0DDD015D-B06C-45D5-8C4C-F59713854639}') },
    @{ Name = 'Music';     Reg = @('My Music', '{4BD8D570-5094-4F3B-B284-9A4BDBF284EC}') },
    @{ Name = 'Desktop';   Reg = @('Desktop', '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}') }
)

$AppDataExclusions = @{
    Local   = @('Microsoft', 'Packages', 'Temp', 'CrashDumps', 'Application Data', 'History')
    Roaming = @('Microsoft', 'Application Data', 'SystemCertificates', 'Protect')
}

$BusyProcesses = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'thunderbird', 'outlook',
                   'ms-teams', 'teams', 'slack', 'discord', 'telegram', 'code', 'onedrive',
                   'dropbox', 'spotify', 'steam', 'winword', 'excel', 'powerpnt')

# ---------------------------------------------------------------------
# Логи
# ---------------------------------------------------------------------
$Stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogDir = Join-Path $env:ProgramData 'ProfileMigration'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$MainLog = Join-Path $LogDir "Migrate_$Stamp.log"
$RoboLog = Join-Path $LogDir "Migrate_${Stamp}_robocopy.log"
try { Start-Transcript -Path $MainLog -Append | Out-Null } catch { }

# ---------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------
function Say([string]$Message, [string]$Color = 'White') {
    Write-Host $Message -ForegroundColor $Color
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N0} КБ' -f ($Bytes / 1KB))
}

function Test-Reparse([string]$Path) {
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return $false
    }
}

function Get-LinkTarget([string]$Path) {
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $t = $i.Target
        if ($t) { return [string]@($t)[0] }
    } catch { }
    return $null
}

# Размер каталога без захода в junction/symlink
function Get-DirSize([string]$Path) {
    $total = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($d)
            foreach ($f in $di.EnumerateFiles()) { $total += $f.Length }
            foreach ($s in $di.EnumerateDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
            }
        } catch { }
    }
    return $total
}

# Копирование с сохранением ACL/владельца. Успех = код robocopy < 8
function Invoke-Copy([string]$Src, [string]$Dst) {
    & robocopy.exe $Src $Dst /E /COPY:DATSO /DCOPY:DAT /B /R:1 /W:1 /XJ /NP "/LOG+:$RoboLog" | Out-Null
    return ($LASTEXITCODE -lt 8)
}

# Проверка: robocopy в режиме /L не находит ничего, что ещё нужно скопировать
function Test-InSync([string]$Src, [string]$Dst) {
    $out = & robocopy.exe $Src $Dst /L /E /XX /XJ /B /NJH /NJS /NDL /NC /NS /NP /FP
    if ($LASTEXITCODE -ge 8) { return $false }
    $pending = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    return ($pending.Count -eq 0)
}

# Удаление каталога, не заходя внутрь junction'ов
function Remove-Tree([string]$Path) {
    & cmd.exe /c rmdir /s /q "$Path" 2>$null | Out-Null
    return (-not (Test-Path -LiteralPath $Path))
}

# Возвращает: Switched | AlreadyLinked | CopiedOnly | Failed | Skipped | Missing | DryRun
function Move-OneFolder([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Src)) { return 'Missing' }

    if (Test-Reparse $Src) {
        $target = Get-LinkTarget $Src
        if ($target -and ($target.TrimEnd('\') -ieq $Dst.TrimEnd('\'))) { return 'AlreadyLinked' }
        Say "  Пропуск: $Src уже является ссылкой на другой путь ($target)." Yellow
        return 'Skipped'
    }

    if ($DryRun) {
        Say "  [DRY-RUN] $Src -> $Dst" Cyan
        return 'DryRun'
    }

    if (-not (Test-Path -LiteralPath $Dst)) {
        New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    }

    if (-not (Invoke-Copy $Src $Dst)) {
        Say "  Копирование завершилось с ошибками (файлы заняты?). Оригинал НЕ тронут." Red
        return 'Failed'
    }
    if (-not (Test-InSync $Src $Dst)) {
        Say "  Копия не совпадает с оригиналом (файлы менялись во время копирования). Оригинал НЕ тронут." Red
        return 'Failed'
    }

    $oldName = (Split-Path $Src -Leaf) + '.migrated_old'
    $old     = Join-Path (Split-Path $Src -Parent) $oldName
    if (Test-Path -LiteralPath $old) {
        Say "  Уже существует $old — удалите или переименуйте его и повторите. Оригинал НЕ тронут." Red
        return 'Failed'
    }

    try {
        Rename-Item -LiteralPath $Src -NewName $oldName -ErrorAction Stop
    } catch {
        Say "  Папка занята процессом, переключить на ссылку не удалось. Копия на D: сохранена, оригинал на месте." Yellow
        return 'CopiedOnly'
    }

    & cmd.exe /c mklink /J "$Src" "$Dst" | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Src)) {
        Rename-Item -LiteralPath $old -NewName (Split-Path $Src -Leaf) -ErrorAction SilentlyContinue
        Say "  Не удалось создать junction. Оригинал возвращён на место." Red
        return 'Failed'
    }

    if (-not $KeepOldCopy) {
        if (-not (Remove-Tree $old)) {
            Say "  Не удалось полностью удалить $old — удалите вручную." Yellow
        }
    }
    return 'Switched'
}

# =====================================================================
try {

# =====================================================================
# 1. ПРОВЕРКИ И ПЛАН
# =====================================================================
$CurrentName = Split-Path $env:USERPROFILE -Leaf
if ([string]::IsNullOrWhiteSpace($TargetUser)) { $TargetUser = $CurrentName }

if ($TargetUser -ine $CurrentName) {
    Say "Ошибка: скрипт меняет реестр текущего пользователя (HKCU), поэтому его можно запускать только" Red
    Say "для того профиля, под которым вы вошли ($CurrentName). Войдите под '$TargetUser' и запустите снова" Red
    Say "от имени администратора." Red
    return
}

$UserRootC = $env:USERPROFILE
$UserRootD = Join-Path $DestRoot $TargetUser

$SourceDrive = Split-Path $UserRootC -Qualifier
$DestDrive   = Split-Path $DestRoot -Qualifier

if ($DestDrive -ieq $SourceDrive) {
    Say "Ошибка: исходный профиль ($UserRootC) и назначение ($DestRoot) находятся на одном диске ($DestDrive)." Red
    return
}

$drive = New-Object System.IO.DriveInfo($DestDrive)
if (-not $drive.IsReady) {
    Say "Ошибка: диск $DestDrive недоступен." Red
    return
}
if ($drive.DriveFormat -ne 'NTFS') {
    Say "Ошибка: диск $DestDrive имеет файловую систему $($drive.DriveFormat), нужна NTFS (права доступа и ссылки)." Red
    return
}

Say "`n>>> Подготовка плана миграции для: $TargetUser <<<" Green
if ($DryRun) { Say "[РЕЖИМ DRY-RUN: изменения не вносятся]" Cyan }

$Plan = New-Object 'System.Collections.Generic.List[object]'

foreach ($lib in $Libraries) {
    $src = Join-Path $UserRootC $lib.Name
    $dst = Join-Path $UserRootD $lib.Name

    $inOneDrive = $false
    foreach ($rn in $lib.Reg) {
        $v = $null
        try { $v = (Get-Item -Path $UsfKey -ErrorAction Stop).GetValue($rn) } catch { }
        if ($v -and ($v -like '*OneDrive*')) { $inOneDrive = $true }
    }
    if ($inOneDrive) {
        Say "Пропуск $($lib.Name): папка перенаправлена в OneDrive." Yellow
        continue
    }
    if (-not (Test-Path -LiteralPath $src)) { continue }

    $Plan.Add([pscustomobject]@{ Kind = 'Library'; Name = $lib.Name; Src = $src; Dst = $dst; Reg = $lib.Reg; Size = [long]0; Status = '' })
}

if (-not $SkipAppData) {
    foreach ($kind in @('Local', 'Roaming')) {
        $srcRoot = Join-Path $UserRootC "AppData\$kind"
        if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $srcRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($AppDataExclusions[$kind] -contains $d.Name) { continue }
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $Plan.Add([pscustomobject]@{
                Kind = "AppData\$kind"; Name = $d.Name; Src = $d.FullName
                Dst = (Join-Path $UserRootD "AppData\$kind\$($d.Name)"); Reg = @(); Size = [long]0; Status = ''
            })
        }
    }
}

if ($Plan.Count -eq 0) {
    Say "Переносить нечего." Yellow
    return
}

Say "Подсчёт размера данных..." Gray
foreach ($p in $Plan) {
    if ((Test-Path -LiteralPath $p.Src) -and -not (Test-Reparse $p.Src)) { $p.Size = Get-DirSize $p.Src }
}
$need = [long](($Plan | Measure-Object -Property Size -Sum).Sum)
$free = $drive.AvailableFreeSpace

Say ("К переносу: {0} элементов, {1}. Свободно на {2}: {3}." -f $Plan.Count, (Format-Size $need), $DestDrive, (Format-Size $free)) Cyan
if ($free -lt ($need * 1.1)) {
    Say "Ошибка: на $DestDrive недостаточно места (нужен запас 10%)." Red
    return
}

$Plan | Sort-Object Size -Descending | Select-Object -First 15 |
    ForEach-Object { Say ("  {0,-16} {1,-30} {2}" -f $_.Kind, $_.Name, (Format-Size $_.Size)) Gray }
if ($Plan.Count -gt 15) { Say "  ... и ещё $($Plan.Count - 15)" Gray }

$busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $BusyProcesses -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique)
if ($busy.Count -gt 0) {
    Say "`nВНИМАНИЕ: запущены программы, которые держат файлы открытыми: $($busy -join ', ')" Yellow
    Say "Закройте их (включая значки в трее) — иначе часть папок будет пропущена." Yellow
}

if (-not $DryRun -and -not $Yes) {
    Say "`nРекомендуется иметь резервную копию важных данных." Yellow
    $answer = Read-Host "Продолжить миграцию? (y/N)"
    if ($answer -notmatch '^(y|yes|д|да)$') { Say "Отменено." Yellow; return }
}

# =====================================================================
# 2. ВЫПОЛНЕНИЕ
# =====================================================================
Say "`n=== Перенос папок ===" Magenta
foreach ($p in $Plan) {
    Say "[$($p.Kind)] $($p.Name) ..." Cyan
    try {
        $p.Status = [string]@(Move-OneFolder -Src $p.Src -Dst $p.Dst)[-1]
    } catch {
        Say "  Ошибка: $($_.Exception.Message)" Red
        $p.Status = 'Failed'
    }
    switch ($p.Status) {
        'Switched'      { Say "  Готово: перенесено и создана ссылка." Green }
        'AlreadyLinked' { Say "  Уже перенесено ранее." Gray }
    }
}

# =====================================================================
# 3. РЕЕСТР (только для успешно переключённых библиотек)
# =====================================================================
$toUpdate = @($Plan | Where-Object { $_.Kind -eq 'Library' -and $_.Status -in @('Switched', 'AlreadyLinked') })
$registryChanged = $false

if ($DryRun) {
    Say "`n[DRY-RUN] Реестр не изменялся." Cyan
} elseif ($toUpdate.Count -gt 0) {
    Say "`n=== Обновление путей в реестре ===" Magenta
    $bak = Join-Path $LogDir "UserShellFolders_before_$Stamp.reg"
    & reg.exe export $UsfKeyReg $bak /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Say "Не удалось сделать резервную копию реестра — шаг пропущен." Red
    } else {
        Say "Резервная копия: $bak" Gray
        foreach ($p in $toUpdate) {
            foreach ($rn in $p.Reg) {
                # Обновляем primary имя (первый элемент) или существующие GUID-параметры
                $existingVal = $null
                try { $existingVal = (Get-Item -Path $UsfKey -ErrorAction Stop).GetValue($rn) } catch { }
                if ($rn -eq $p.Reg[0] -or $null -ne $existingVal) {
                    Set-ItemProperty -Path $UsfKey -Name $rn -Value $p.Dst -Type ExpandString -Force
                }
            }
        }
        $registryChanged = $true
        Say "Реестр обновлён для: $(($toUpdate | ForEach-Object Name) -join ', ')" Green
    }
}

# =====================================================================
# 4. ИТОГ
# =====================================================================
Say "`n=== Итог ===" Magenta
$Plan | Group-Object Status | ForEach-Object { Say ("  {0,-14} {1}" -f $_.Name, $_.Count) White }

$problems = @($Plan | Where-Object { $_.Status -in @('Failed', 'CopiedOnly') })
if ($problems.Count -gt 0) {
    Say "`nНе переключены (оригиналы на C: целы, повторный запуск продолжит работу):" Yellow
    $problems | ForEach-Object { Say "  - [$($_.Kind)] $($_.Name): $($_.Status)" Yellow }
    Say "Совет: закройте программы и запустите скрипт ещё раз (или после перезагрузки, до запуска приложений)." Yellow
}
if ($KeepOldCopy -and -not $DryRun) {
    Say "`nОригиналы сохранены как *.migrated_old. После проверки удалите их вручную." Yellow
}

if ($registryChanged -and -not $NoExplorerRestart) {
    Say "`nПерезапуск Проводника..." Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

Say "`nЛоги: $LogDir" Gray
Say "[ГОТОВО]" Green

} finally {
    try { Stop-Transcript | Out-Null } catch { }
}

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Безопасный возврат профиля пользователя с диска D: обратно на системный диск C:.

.DESCRIPTION
    Что делает:
      1. Для каждой папки (Downloads, Documents, Videos, Pictures, Music, Desktop и подпапки AppData\Local / Roaming)
         убирает junction на C:, копирует данные с D: на C: и проверяет, что копия полная.
      2. Только после успешной проверки удаляет данные на D:.
      3. Если копирование не удалось — данные на D: остаются нетронутыми, а junction восстанавливается.
      4. Сбрасывает пути в реестре к %USERPROFILE%\... (для тех библиотек, что указывали на диск D:).

    Отличия от простых скриптов:
      - проверка результата robocopy и повторное сравнение перед удалением;
      - сохранение ACL и метаданных;
      - режим -DryRun (только показать план без изменений);
      - проверки диска и свободного места с запасом;
      - резервная копия ветки реестра;
      - подробные логи в %ProgramData%\ProfileMigration;
      - подтверждение перед стартом.

.PARAMETER TargetUser
    Имя папки профиля. По умолчанию — текущий пользователь (единственный допустимый вариант).
.PARAMETER DestRoot
    Корень, куда профиль был перенесён. По умолчанию D:\Users.
.PARAMETER DryRun
    Только показать, что будет сделано.
.PARAMETER SkipAppData
    Не возвращать AppData (только пользовательские библиотеки: Downloads, Documents и т.д.).
.PARAMETER KeepOldCopy
    Не удалять данные на D:, а переименовать в <папка>.rollback_old (удалите вручную после проверки).
.PARAMETER NoExplorerRestart
    Не перезапускать Проводник.
.PARAMETER Yes
    Не задавать вопросы подтверждения.

.EXAMPLE
    .\Rollback-UserToDriveC.ps1 -DryRun
    .\Rollback-UserToDriveC.ps1 -KeepOldCopy
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

$DefaultPaths = @{
    'Downloads'     = '%USERPROFILE%\Downloads'
    'Documents'     = '%USERPROFILE%\Documents'
    'Videos'        = '%USERPROFILE%\Videos'
    'Pictures'      = '%USERPROFILE%\Pictures'
    'Music'         = '%USERPROFILE%\Music'
    'Desktop'       = '%USERPROFILE%\Desktop'
    'AppData'       = '%USERPROFILE%\AppData\Roaming'
    'Local AppData' = '%USERPROFILE%\AppData\Local'
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
$MainLog = Join-Path $LogDir "Rollback_$Stamp.log"
$RoboLog = Join-Path $LogDir "Rollback_${Stamp}_robocopy.log"
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

function Invoke-Copy([string]$Src, [string]$Dst) {
    & robocopy.exe $Src $Dst /E /COPY:DATSO /DCOPY:DAT /B /R:1 /W:1 /XJ /NP "/LOG+:$RoboLog" | Out-Null
    return ($LASTEXITCODE -lt 8)
}

function Test-InSync([string]$Src, [string]$Dst) {
    $out = & robocopy.exe $Src $Dst /L /E /XX /XJ /B /NJH /NJS /NDL /NC /NS /NP /FP
    if ($LASTEXITCODE -ge 8) { return $false }
    $pending = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    return ($pending.Count -eq 0)
}

function Remove-Tree([string]$Path) {
    & cmd.exe /c rmdir /s /q "$Path" 2>$null | Out-Null
    return (-not (Test-Path -LiteralPath $Path))
}

# $SrcD — данные на D:, $DstC — место назначения на C:
# Возвращает: Restored | Failed | Skipped | Missing | DryRun
function Restore-OneFolder([string]$SrcD, [string]$DstC) {
    if (-not (Test-Path -LiteralPath $SrcD)) { return 'Missing' }

    if (Test-Reparse $SrcD) {
        Say "  Пропуск: $SrcD сам является ссылкой." Yellow
        return 'Skipped'
    }

    if ($DryRun) {
        Say "  [DRY-RUN] $SrcD -> $DstC" Cyan
        return 'DryRun'
    }

    $wasLink  = $false
    $createdC = $false

    if (Test-Path -LiteralPath $DstC) {
        if (Test-Reparse $DstC) {
            $target = Get-LinkTarget $DstC
            if ($target -and ($target.TrimEnd('\') -ine $SrcD.TrimEnd('\'))) {
                Say "  Пропуск: $DstC — ссылка на другой путь ($target)." Yellow
                return 'Skipped'
            }
            # rmdir без /s удаляет только саму ссылку, не содержимое
            & cmd.exe /c rmdir "$DstC" | Out-Null
            if (Test-Path -LiteralPath $DstC) {
                Say "  Не удалось удалить ссылку $DstC (папка занята). Данные на D: не тронуты." Yellow
                return 'Failed'
            }
            $wasLink = $true
        }
    }

    if (-not (Test-Path -LiteralPath $DstC)) {
        New-Item -ItemType Directory -Path $DstC -Force | Out-Null
        $createdC = $true
    }

    $ok = (Invoke-Copy $SrcD $DstC) -and (Test-InSync $SrcD $DstC)

    if (-not $ok) {
        Say "  Копирование не удалось или копия неполная. Данные на D: НЕ тронуты." Red
        if ($wasLink -and $createdC) {
            # возвращаем исходное состояние: убираем частичную копию и восстанавливаем ссылку
            [void](Remove-Tree $DstC)
            & cmd.exe /c mklink /J "$DstC" "$SrcD" | Out-Null
            if (Test-Path -LiteralPath $DstC) { Say "  Junction на D: восстановлен." Gray }
            else { Say "  ВНИМАНИЕ: junction восстановить не удалось: $DstC" Red }
        }
        return 'Failed'
    }

    if ($KeepOldCopy) {
        $oldName = (Split-Path $SrcD -Leaf) + '.rollback_old'
        try { Rename-Item -LiteralPath $SrcD -NewName $oldName -ErrorAction Stop }
        catch { Say "  Не удалось переименовать $SrcD — оставлена как есть." Yellow }
    } else {
        if (-not (Remove-Tree $SrcD)) {
            Say "  Не удалось полностью удалить $SrcD — удалите вручную." Yellow
        }
    }
    return 'Restored'
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

# Если текущий USERPROFILE на C:, используем его; если он уже на D:, целевой корень на C:\Users\<User>
if ($env:USERPROFILE.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) {
    $UserRootC = $env:USERPROFILE
} else {
    $UserRootC = Join-Path "$($env:SystemDrive)\Users" $TargetUser
}

$UserRootD = Join-Path $DestRoot $TargetUser

if (-not (Test-Path -LiteralPath $UserRootD)) {
    Say "Ошибка: папка $UserRootD не найдена — возвращать нечего." Red
    return
}

$DestDrive       = Split-Path $DestRoot -Qualifier
$destDrivePrefix = "$DestDrive\"
$SysDrive        = New-Object System.IO.DriveInfo($env:SystemDrive)

if ($DestDrive -ieq $env:SystemDrive) {
    Say "Ошибка: источник находится на системном диске ($DestDrive)." Red
    return
}
if ($SysDrive.DriveFormat -ne 'NTFS') {
    Say "Ошибка: системный диск не NTFS ($($SysDrive.DriveFormat))." Red
    return
}

Say "`n>>> Подготовка плана возврата для: $TargetUser <<<" Green
if ($DryRun) { Say "[РЕЖИМ DRY-RUN: изменения не вносятся]" Cyan }

$Plan = New-Object 'System.Collections.Generic.List[object]'

foreach ($lib in $Libraries) {
    $srcD = Join-Path $UserRootD $lib.Name
    if (-not (Test-Path -LiteralPath $srcD)) { continue }
    $Plan.Add([pscustomobject]@{ Kind = 'Library'; Name = $lib.Name; Src = $srcD; Dst = (Join-Path $UserRootC $lib.Name); Reg = $lib.Reg; Size = [long]0; Status = '' })
}

if (-not $SkipAppData) {
    foreach ($kind in @('Local', 'Roaming')) {
        $srcRoot = Join-Path $UserRootD "AppData\$kind"
        if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $srcRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            $Plan.Add([pscustomobject]@{
                Kind = "AppData\$kind"; Name = $d.Name; Src = $d.FullName
                Dst = (Join-Path $UserRootC "AppData\$kind\$($d.Name)"); Reg = @(); Size = [long]0; Status = ''
            })
        }
    }
}

if ($Plan.Count -eq 0) {
    Say "На $UserRootD нет папок для возврата." Yellow
    return
}

Say "Подсчёт размера данных..." Gray
foreach ($p in $Plan) {
    if ((Test-Path -LiteralPath $p.Src) -and -not (Test-Reparse $p.Src)) { $p.Size = Get-DirSize $p.Src }
}
$need = [long](($Plan | Measure-Object -Property Size -Sum).Sum)
$free = $SysDrive.AvailableFreeSpace

Say ("К возврату: {0} элементов, {1}. Свободно на {2}: {3}." -f $Plan.Count, (Format-Size $need), $env:SystemDrive, (Format-Size $free)) Cyan
if ($free -lt ($need * 1.1)) {
    Say "Ошибка: на $($env:SystemDrive) недостаточно места (нужен запас 10%)." Red
    return
}

$Plan | Sort-Object Size -Descending | Select-Object -First 15 |
    ForEach-Object { Say ("  {0,-16} {1,-30} {2}" -f $_.Kind, $_.Name, (Format-Size $_.Size)) Gray }
if ($Plan.Count -gt 15) { Say "  ... и ещё $($Plan.Count - 15)" Gray }

$busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $BusyProcesses -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique)
if ($busy.Count -gt 0) {
    Say "`nВНИМАНИЕ: запущены программы, которые держат файлы открытыми: $($busy -join ', ')" Yellow
    Say "Закройте их (включая значки в трее) — иначе часть папок не будет возвращена." Yellow
}

if (-not $DryRun -and -not $Yes) {
    $answer = Read-Host "`nПродолжить возврат на диск C:? (y/N)"
    if ($answer -notmatch '^(y|yes|д|да)$') { Say "Отменено." Yellow; return }
}

# =====================================================================
# 2. ВЫПОЛНЕНИЕ
# =====================================================================
Say "`n=== Возврат папок ===" Magenta
foreach ($p in $Plan) {
    Say "[$($p.Kind)] $($p.Name) ..." Cyan
    try {
        $p.Status = [string]@(Restore-OneFolder -SrcD $p.Src -DstC $p.Dst)[-1]
    } catch {
        Say "  Ошибка: $($_.Exception.Message)" Red
        $p.Status = 'Failed'
    }
    if ($p.Status -eq 'Restored') { Say "  Готово: возвращено на C:." Green }
}

# =====================================================================
# 3. РЕЕСТР (сброс значений, указывающих на D:)
# =====================================================================
$registryChanged = $false

if ($DryRun) {
    Say "`n[DRY-RUN] Реестр не изменялся." Cyan
} else {
    Say "`n=== Сброс путей в реестре ===" Magenta
    $bak = Join-Path $LogDir "UserShellFolders_before_rollback_$Stamp.reg"
    & reg.exe export $UsfKeyReg $bak /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Say "Не удалось сделать резервную копию реестра — шаг пропущен." Red
    } else {
        Say "Резервная копия: $bak" Gray
        $prefix = $DestRoot.TrimEnd('\') + '\'

        # 1. Библиотеки пользователя
        foreach ($lib in $Libraries) {
            foreach ($rn in $lib.Reg) {
                $current = $null
                try { $current = (Get-Item -Path $UsfKey -ErrorAction Stop).GetValue($rn) } catch { }
                if ($current -and ($current.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                                   $current.StartsWith($destDrivePrefix, [StringComparison]::OrdinalIgnoreCase))) {
                    Set-ItemProperty -Path $UsfKey -Name $rn -Value $DefaultPaths[$lib.Name] -Type ExpandString -Force
                    $registryChanged = $true
                }
            }
        }

        # 2. Проверка AppData / Local AppData (если они указывали на D:)
        foreach ($rn in @('AppData', 'Local AppData')) {
            $current = $null
            try { $current = (Get-Item -Path $UsfKey -ErrorAction Stop).GetValue($rn) } catch { }
            if ($current -and ($current.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                               $current.StartsWith($destDrivePrefix, [StringComparison]::OrdinalIgnoreCase))) {
                Set-ItemProperty -Path $UsfKey -Name $rn -Value $DefaultPaths[$rn] -Type ExpandString -Force
                $registryChanged = $true
            }
        }

        if ($registryChanged) { Say "Пути в реестре сброшены на %USERPROFILE%." Green }
        else { Say "Пути в реестре уже стандартные — менять нечего." Gray }
    }
}

# =====================================================================
# 4. ИТОГ
# =====================================================================
Say "`n=== Итог ===" Magenta
$Plan | Group-Object Status | ForEach-Object { Say ("  {0,-14} {1}" -f $_.Name, $_.Count) White }

$problems = @($Plan | Where-Object { $_.Status -in @('Failed', 'Skipped') })
if ($problems.Count -gt 0) {
    Say "`nНе возвращены (данные на D: целы, повторный запуск продолжит работу):" Yellow
    $problems | ForEach-Object { Say "  - [$($_.Kind)] $($_.Name): $($_.Status)" Yellow }
    Say "Совет: закройте программы и запустите скрипт ещё раз (или после перезагрузки, до запуска приложений)." Yellow
}
if ($KeepOldCopy -and -not $DryRun) {
    Say "`nДанные на D: сохранены как *.rollback_old. После проверки удалите их вручную." Yellow
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

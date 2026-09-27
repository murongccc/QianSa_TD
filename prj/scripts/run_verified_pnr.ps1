# 使用最近一次 TD GUI 生成的工程配置运行综合和 P&R；不生成 bitstream。
# 如遇 PHY-8023/RUN-8102，自动从本次失败数据库执行已验证的重布线。
param([string]$TdCommand = 'E:\AnLuTD\bin\td_commands_prompt.exe')
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$synTemplate = Join-Path $projectDir 'SD_to_Video_Runs/syn_1'
$phyTemplate = Join-Path $projectDir 'SD_to_Video_Runs/phy_1'
$logDir = Join-Path $projectDir 'log'
$synDir = Join-Path $logDir 'verified_pnr_syn'
$phyDir = Join-Path $logDir 'verified_pnr_phy'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$pnrStartTime = Get-Date
if (-not (Test-Path -LiteralPath $TdCommand)) { throw "TD executable missing: $TdCommand" }
foreach ($template in @($synTemplate, $phyTemplate)) {
    foreach ($file in @('SD_to_Video.prj', 'SD_to_Video.tcl', 'settings.cfg')) {
        if (-not (Test-Path -LiteralPath (Join-Path $template $file))) {
            throw "Missing GUI run configuration: $template/$file"
        }
    }
}
New-Item -ItemType Directory -Force $synDir, $phyDir | Out-Null
foreach ($item in @(@($synTemplate, $synDir), @($phyTemplate, $phyDir))) {
    foreach ($file in @('SD_to_Video.prj', 'SD_to_Video.tcl', 'settings.cfg')) {
        Copy-Item -LiteralPath (Join-Path $item[0] $file) -Destination (Join-Path $item[1] $file)
    }
    [System.IO.File]::WriteAllText((Join-Path $item[1] 'run.tcl'), "source ./SD_to_Video.tcl`n", $utf8)
}
$synSettingsPath = Join-Path $synDir 'settings.cfg'
$synSettings = [System.IO.File]::ReadAllText($synSettingsPath)
$synSettings = $synSettings -replace '(?m)^set start_step .+$', 'set start_step read_design'
$synSettings = $synSettings -replace '(?m)^set end_step .+$', 'set end_step opt_gate'
[System.IO.File]::WriteAllText($synSettingsPath, $synSettings, $utf8)
$phySettingsPath = Join-Path $phyDir 'settings.cfg'
$phySettings = [System.IO.File]::ReadAllText($phySettingsPath)
$phySettings = $phySettings -replace '(?m)^set start_step .+$', 'set start_step opt_place'
$phySettings = $phySettings -replace '(?m)^set end_step .+$', 'set end_step opt_route'
$phySettings = $phySettings -replace '(?m)^set parent .+$', 'set parent ../verified_pnr_syn'
[System.IO.File]::WriteAllText($phySettingsPath, $phySettings, $utf8)

function Invoke-TdStage([string]$directory, [string]$script, [string]$log) {
    Push-Location $directory
    try {
        & $TdCommand $script *> $log
        $stageExitCode = $LASTEXITCODE
    } finally { Pop-Location }
    # TD 某些命令失败时仍返回 0，必须同时检查日志。
    $stageLog = [System.IO.File]::ReadAllText($log)
    return @{ ExitCode = $stageExitCode; Log = $stageLog }
}
Write-Output 'Running synthesis...'
$synLog = Join-Path $logDir 'verified_pnr_syn.log'
$synResult = Invoke-TdStage $synDir 'run.tcl' $synLog
if ($synResult.ExitCode -ne 0 -or $synResult.Log -match '\bERROR\b') {
    throw "Synthesis failed; see $synLog"
}
$phyLog = Join-Path $logDir 'verified_pnr_phy.log'
Write-Output 'Running placement and routing...'
$phyResult = Invoke-TdStage $phyDir 'run.tcl' $phyLog
if ($phyResult.ExitCode -ne 0 -or $phyResult.Log -match '\bERROR\b') {
    if ($phyResult.Log -notmatch 'PHY-8023' -or $phyResult.Log -notmatch 'RUN-8102') {
        throw "P&R failed; see $phyLog"
    }
    $ecoPath = Join-Path $phyDir 'SD_to_Video_eco_pr.db'
    if (-not (Test-Path -LiteralPath $ecoPath) -or
        (Get-Item -LiteralPath $ecoPath).LastWriteTime -lt $pnrStartTime) {
        throw 'Current failed ECO database missing; refusing to reuse an old database.'
    }
    Write-Output 'Routing conflict detected; rerouting the current ECO database...'
    $recoveryScript = "set resource_route_run_dir [pwd]`nsource ../../scripts/recover_incremental_route.tcl`n"
    [System.IO.File]::WriteAllText((Join-Path $phyDir 'recover.tcl'), $recoveryScript, $utf8)
    $recoveryLog = Join-Path $logDir 'verified_pnr_recovery.log'
    $recoveryResult = Invoke-TdStage $phyDir 'recover.tcl' $recoveryLog
    if ($recoveryResult.ExitCode -ne 0 -or $recoveryResult.Log -match '\bERROR\b') {
        throw "Rerouting failed; see $recoveryLog"
    }
    $reportPrefix = 'recovered'
} else { $reportPrefix = 'SD_to_Video' }
$areaPath = Join-Path $phyDir ($reportPrefix + '_phy.area')
$timingPath = Join-Path $phyDir ($reportPrefix + '_phy.ts')
if (-not (Test-Path -LiteralPath $areaPath) -or -not (Test-Path -LiteralPath $timingPath)) {
    throw 'Final resource or timing report missing.'
}
if ((Get-Item -LiteralPath $areaPath).LastWriteTime -lt $pnrStartTime -or
    (Get-Item -LiteralPath $timingPath).LastWriteTime -lt $pnrStartTime) {
    throw 'Final reports are stale.'
}
$timingText = [System.IO.File]::ReadAllText($timingPath)
Write-Output "Final resources: $areaPath"
Write-Output "Final timing: $timingPath"
Write-Output $timingText.Trim()
if ($timingText -match '(?:SWNS|HWNS):\s*-\d') {
    throw 'Routing completed, but setup/hold timing is not closed.'
}
Write-Output 'P&R completed; routing and setup/hold checks passed. No bitstream generated.'

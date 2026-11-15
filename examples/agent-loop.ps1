# 一个 agent 的典型用法：挂角标 → 每步更新 → 收尾。
# 直接运行可以看效果：powershell -ExecutionPolicy Bypass -File .\agent-loop.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$badge = Join-Path (Split-Path -Parent $here) 'dsh-badge.ps1'

$state = Join-Path $env:TEMP 'dsh-badge-state.json'
$hb = Join-Path $env:TEMP 'dsh-badge-hb.txt'
$cancel = Join-Path $env:TEMP 'dsh-badge-cancel.txt'
Remove-Item $cancel -ErrorAction SilentlyContinue

function Set-Badge {
    param([string]$Title, [string]$Detail, [int]$Step, [int]$Total, [string]$Tone = 'busy')
    @{ title = $Title; detail = $Detail; step = $Step; total = $Total; tone = $Tone } |
        ConvertTo-Json | Set-Content $state -Encoding UTF8
    (Get-Item $hb).LastWriteTime = Get-Date
}

function Test-Cancelled {
    if (Test-Path $cancel) { Write-Host '用户点了取消，收手'; return $true }
    return $false
}

# 1. 起角标（分离进程，不占用当前 shell）
Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$badge`"",
    '-StateFile', "`"$state`"", '-Heartbeat', "`"$hb`"", '-Seconds', '20'
)
Start-Sleep -Seconds 2

# 2. 干活，每步更新一次
$steps = @(
    '读取输入',
    '抓取 3 个来源',
    '整理成表格',
    '写入结果文件'
)

for ($i = 0; $i -lt $steps.Count; $i++) {
    if (Test-Cancelled) { break }
    Set-Badge -Title $steps[$i] -Detail "共 $($steps.Count) 步" -Step ($i + 1) -Total $steps.Count
    Start-Sleep -Seconds 2
}

# 3. 收尾：先变绿，留两秒给人看到，再停
Set-Badge -Title '已完成' -Detail '结果在 output.md' -Step $steps.Count -Total $steps.Count -Tone 'done'
Start-Sleep -Seconds 3
powershell -ExecutionPolicy Bypass -File $badge -Stop

Remove-Item $state, $hb, $cancel -ErrorAction SilentlyContinue

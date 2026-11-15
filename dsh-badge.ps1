param(
    [string]$Text = 'DSH 正在操作电脑',
    [string]$Detail = '',
    [int]$Seconds = 180,
    [string]$Heartbeat = '',
    [string]$StateFile = '',
    [string]$CancelFile = '',
    [switch]$Clickable,
    [switch]$Stop,
    [switch]$Captureable,
    [ValidateSet('BottomRight', 'BottomLeft', 'TopRight', 'TopLeft', 'BottomCenter')]
    [string]$Anchor = 'BottomRight',
    [int]$Monitor = 0,
    [double]$Opacity = 0.92,
    [string]$Accent = '#00D4FF',
    [ValidateSet('zh', 'en')]
    [string]$Lang = 'zh'
)

# ---------------------------------------------------------------------------
# 停掉已在跑的角标，避免叠出两个
# ---------------------------------------------------------------------------
# 用 pid 文件记录当前实例，而不是扫命令行。
# 扫命令行会误杀启动器：调用方用 Start-Process 拉起角标时，它自己的命令行里也带着脚本名。
$PidFile = Join-Path $env:TEMP 'dsh-badge.pid'

function Stop-PreviousBadge {
    if (-not (Test-Path $PidFile)) { return }
    $oldPid = 0
    try { $oldPid = [int]((Get-Content $PidFile -Raw -ErrorAction Stop).Trim()) } catch { return }
    if ($oldPid -le 0 -or $oldPid -eq $PID) { return }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $oldPid" -ErrorAction SilentlyContinue
    if ($proc -and $proc.CommandLine -like '*dsh-badge.ps1*') {
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

Stop-PreviousBadge
if ($Stop) {
    if ($Heartbeat -ne '' -and (Test-Path $Heartbeat)) { Remove-Item $Heartbeat -Force -ErrorAction SilentlyContinue }
    return
}

Set-Content -Path $PidFile -Value $PID -Encoding ASCII

if ($Heartbeat -ne '') {
    New-Item -ItemType File -Path $Heartbeat -Force | Out-Null
    (Get-Item $Heartbeat).LastWriteTime = Get-Date
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BadgeNative {
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20;
    public const int WS_EX_TOOLWINDOW = 0x80;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
}
"@


Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BadgeDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
}
"@

# 必须赶在任何窗口创建之前声明 DPI 感知，否则坐标会被系统再放大一次（150% 缩放时角标落到屏幕外）
try {
    if (-not [BadgeDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [BadgeDpi]::SetProcessDpiAwareness(2) | Out-Null }
} catch {
    try { [BadgeDpi]::SetProcessDpiAwareness(2) | Out-Null } catch { }
}

# ---------------------------------------------------------------------------
# 文案
# ---------------------------------------------------------------------------
$L = @{
    zh = @{
        running  = '已运行 {0}s'
        heartbeat = '心跳上限 {1}s（闲置 {2}s）'
        countdown = '无操作 {2}s 后自动隐藏'
        cancel   = '取消'
        step     = '第 {0} / {1} 步'
    }
    en = @{
        running  = 'running {0}s'
        heartbeat = 'heartbeat {1}s (idle {2}s)'
        countdown = 'hides in {2}s'
        cancel   = 'Cancel'
        step     = 'step {0} / {1}'
    }
}
$S = $L[$Lang]

$ToneColor = @{
    busy    = $Accent
    waiting = '#F5A524'
    error   = '#F31260'
    done    = '#17C964'
}

function Brush([string]$hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

# ---------------------------------------------------------------------------
# 窗口
# ---------------------------------------------------------------------------
$window = New-Object System.Windows.Window
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.Width = 392
$window.Height = 96
$window.Opacity = $Opacity
$window.WindowStartupLocation = 'Manual'

# 位置：按 -Anchor 落在选中的显示器工作区内
$screens = [System.Windows.Forms.Screen]::AllScreens
$target = if ($Monitor -ge 0 -and $Monitor -lt $screens.Count) { $screens[$Monitor] } else { $screens[0] }
$work = $target.WorkingArea
$gap = 28

# 按锚点算 WPF 坐标。$work 在本机是物理像素，而窗口可能被系统再乘一次缩放，
# 所以统一换算到「WPF 坐标」：物理工作区 / 缩放比例。
function Get-BadgePosition([double]$scale) {
    if ($scale -le 0) { $scale = 1.0 }
    $wD = $work.Width / $scale
    $hD = $work.Height / $scale
    $gw = $window.Width
    $gh = $window.Height
    switch ($Anchor) {
        'BottomRight'  { return @(($wD - $gw - $gap), ($hD - $gh - $gap)) }
        'BottomLeft'   { return @($gap, ($hD - $gh - $gap)) }
        'TopRight'     { return @(($wD - $gw - $gap), $gap) }
        'TopLeft'      { return @($gap, $gap) }
        'BottomCenter' { return @((($wD - $gw) / 2), ($hD - $gh - $gap)) }
        default        { return @(($wD - $gw - $gap), ($hD - $gh - $gap)) }
    }
}

$pos = Get-BadgePosition 1.0
$window.Left = $pos[0]
$window.Top = $pos[1]

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = 12
$border.Padding = '14,10,14,10'
$border.Background = Brush '#E6191B20'
$border.BorderBrush = Brush ('#66' + $Accent.TrimStart('#'))
$border.BorderThickness = 1

$grid = New-Object System.Windows.Controls.Grid
$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
$col2 = New-Object System.Windows.Controls.ColumnDefinition
$col2.Width = [System.Windows.GridLength]::Auto
$grid.ColumnDefinitions.Add($col2)

$stack = New-Object System.Windows.Controls.StackPanel

$head = New-Object System.Windows.Controls.StackPanel
$head.Orientation = 'Horizontal'

$dot = New-Object System.Windows.Controls.Border
$dot.Width = 8
$dot.Height = 8
$dot.CornerRadius = 4
$dot.Background = Brush $ToneColor.busy
$dot.VerticalAlignment = 'Center'
$dot.Margin = '0,0,8,0'

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = $Text
$title.Foreground = [System.Windows.Media.Brushes]::White
$title.FontSize = 13
$title.FontWeight = 'SemiBold'
$title.TextWrapping = 'Wrap'
$title.TextTrimming = 'CharacterEllipsis'
$title.MaxWidth = 290

$head.Children.Add($dot) | Out-Null
$head.Children.Add($title) | Out-Null

$detailLine = New-Object System.Windows.Controls.TextBlock
$detailLine.Text = $Detail
$detailLine.Foreground = Brush '#99A8B6C4'
$detailLine.FontSize = 11
$detailLine.Margin = '16,3,0,0'
$detailLine.TextWrapping = 'Wrap'
$detailLine.TextTrimming = 'CharacterEllipsis'
$detailLine.MaxWidth = 290
$detailLine.Visibility = if ($Detail -eq '') { 'Collapsed' } else { 'Visible' }

$status = New-Object System.Windows.Controls.TextBlock
$status.Text = ''
$status.Foreground = Brush '#7793A8B6'
$status.FontSize = 10
$status.Margin = '16,3,0,0'

$bar = New-Object System.Windows.Controls.ProgressBar
$bar.Height = 3
$bar.Margin = '0,7,0,0'
$bar.Foreground = Brush $Accent
$bar.Background = Brush '#33263238'
$bar.BorderThickness = 0
$bar.Visibility = 'Collapsed'
$bar.Maximum = 1
$bar.Value = 0

$stack.Children.Add($head) | Out-Null
$stack.Children.Add($detailLine) | Out-Null
$stack.Children.Add($status) | Out-Null
$stack.Children.Add($bar) | Out-Null

[System.Windows.Controls.Grid]::SetColumn($stack, 0)
$grid.Children.Add($stack) | Out-Null

$cancelBtn = $null
if ($Clickable) {
    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = '×'
    $cancelBtn.Width = 22
    $cancelBtn.Height = 22
    $cancelBtn.FontSize = 14
    $cancelBtn.Foreground = Brush '#CCFFFFFF'
    $cancelBtn.Background = [System.Windows.Media.Brushes]::Transparent
    $cancelBtn.BorderThickness = 0
    $cancelBtn.Cursor = 'Hand'
    $cancelBtn.VerticalAlignment = 'Top'
    $cancelBtn.ToolTip = $S.cancel
    $cancelBtn.Add_Click({
        if ($CancelFile -ne '') {
            try { Set-Content -Path $CancelFile -Value (Get-Date -Format o) -Encoding UTF8 } catch { }
        }
        $window.Close()
    })
    [System.Windows.Controls.Grid]::SetColumn($cancelBtn, 1)
    $grid.Children.Add($cancelBtn) | Out-Null
}

$border.Child = $grid
$window.Content = $border

$window.Add_SourceInitialized({
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $ex = [BadgeNative]::GetWindowLong($handle, [BadgeNative]::GWL_EXSTYLE)
    $ex = $ex -bor [BadgeNative]::WS_EX_NOACTIVATE -bor [BadgeNative]::WS_EX_TOOLWINDOW
    # 只有当角标不可点击时才穿透；要能点取消，就得让窗口接收鼠标
    if (-not $Clickable) { $ex = $ex -bor [BadgeNative]::WS_EX_TRANSPARENT }
    [BadgeNative]::SetWindowLong($handle, [BadgeNative]::GWL_EXSTYLE, $ex) | Out-Null
    if (-not $Captureable) {
        [BadgeNative]::SetWindowDisplayAffinity($handle, [BadgeNative]::WDA_EXCLUDEFROMCAPTURE) | Out-Null
    }
    # 窗口若是 DPI 不感知的（powershell.exe 常见），系统会把 WPF 坐标再乘一次缩放，
    # 角标会跑到屏幕外。按真实 DPI 反算回 WPF 坐标。
    try {
        $dpi = [BadgeNative]::GetDpiForWindow($handle)
        if ($dpi -gt 0) {
            $p = Get-BadgePosition ($dpi / 96.0)
            $window.Left = $p[0]
            $window.Top = $p[1]
        }
    } catch { }
})

# ---------------------------------------------------------------------------
# 状态文件：{"title","detail","step","total","tone"}，agent 每步覆写
# ---------------------------------------------------------------------------
function Apply-State {
    if ($StateFile -eq '' -or -not (Test-Path $StateFile)) { return }
    try {
        $st = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch { return }

    if ($st.title) { $title.Text = [string]$st.title }
    if ($null -ne $st.detail) {
        $detailLine.Text = [string]$st.detail
        $detailLine.Visibility = if ($detailLine.Text -eq '') { 'Collapsed' } else { 'Visible' }
    }
    if ($st.step -and $st.total) {
        $status.Text = ($S.step -f [int]$st.step, [int]$st.total)
        $bar.Visibility = 'Visible'
        $bar.Maximum = [double]$st.total
        $bar.Value = [double]$st.step
    }
    if ($st.tone -and $ToneColor.ContainsKey([string]$st.tone)) {
        $c = Brush $ToneColor[[string]$st.tone]
        $dot.Background = $c
        $bar.Foreground = $c
    }
}

# ---------------------------------------------------------------------------
# 计时 + 轮询
# ---------------------------------------------------------------------------
$script:elapsed = 0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    $script:elapsed += 1

    if ($Heartbeat -ne '') {
        $idle = $Seconds + 1
        if (Test-Path $Heartbeat) {
            $idle = [int]((Get-Date) - (Get-Item $Heartbeat).LastWriteTime).TotalSeconds
        }
        $status.Text = (($S.running -f $script:elapsed) + ' · ' + ($S.heartbeat -f 0, $Seconds, $idle))
        if ($idle -ge $Seconds) { $window.Close() }
    }
    else {
        $left = [Math]::Max(0, $Seconds - $script:elapsed)
        $status.Text = (($S.running -f $script:elapsed) + ' · ' + ($S.countdown -f 0, $Seconds, $left))
        if ($script:elapsed -ge $Seconds) { $window.Close() }
    }
})
$timer.Start()

$poller = New-Object System.Windows.Threading.DispatcherTimer
$poller.Interval = [TimeSpan]::FromMilliseconds(400)
$poller.Add_Tick({ Apply-State })
if ($StateFile -ne '') { $poller.Start() }

Apply-State

$window.Add_Closed({
    $timer.Stop()
    $poller.Stop()
    try {
        if ((Test-Path $PidFile) -and ((Get-Content $PidFile -Raw).Trim() -eq [string]$PID)) {
            Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
})
$window.ShowDialog() | Out-Null

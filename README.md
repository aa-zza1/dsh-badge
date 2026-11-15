# dsh-badge

给桌面 agent 用的「正在操作」角标。一个贴在屏幕角落的小窗口，告诉人：**AI 现在正在动你的电脑，它在干什么，还剩几步。**

![效果](docs/demo.png)

## 为什么需要

agent 操作桌面时，鼠标会自己动、窗口会自己弹。人看不见提示，就会以为卡死了、或者以为已经做完了，然后去打断它。

系统通知的问题是不持久（几秒就消失）；托盘气泡的问题是会被折叠。这个角标是**常驻的**，只要 agent 还在干，它就在右下角亮着；心跳一断，它自己消失。

## 特性

- **点击穿透**：默认不挡鼠标，角标下面照常能点
- **不进截图**：`WDA_EXCLUDEFROMCAPTURE`，录屏和截图里都不会出现，只有人眼能看到（自检时用 `-Captureable` 关掉）
- **状态可变**：写一个 JSON 文件，标题、说明、步骤、颜色实时更新，不用重启
- **心跳自灭**：调用方持续 touch 心跳文件，静默超过阈值就自己消失，不会留下幽灵窗口
- **可取消**：加 `-Clickable` 就会出现 × 按钮，点了写一个标记文件，agent 读到就停手
- **能定位**：四角 + 底部居中、多显示器、透明度、主题色

## 快速开始

```powershell
# 最简单
powershell -ExecutionPolicy Bypass -File .\dsh-badge.ps1 -Text "正在操作电脑" -Seconds 60

# 带副标题和步骤
powershell -ExecutionPolicy Bypass -File .\dsh-badge.ps1 -Text "正在抓取网页" -Detail "第 2 个来源" -Seconds 120

# 心跳模式：agent 每 30 秒 touch 一次，静默 90 秒就消失
powershell -ExecutionPolicy Bypass -File .\dsh-badge.ps1 -Heartbeat "$env:TEMP\dsh-badge.hb" -Seconds 90

# 停止
powershell -ExecutionPolicy Bypass -File .\dsh-badge.ps1 -Stop
```

## 状态文件（多步任务用这个）

角标每 400ms 轮询一次状态文件，随便覆写，立即生效：

```powershell
$state = @{ title = "正在改脚本"; detail = "写入 README"; step = 2; total = 5; tone = "busy" }
$state | ConvertTo-Json | Set-Content "$env:TEMP\badge.json" -Encoding UTF8
```

```powershell
powershell -ExecutionPolicy Bypass -File .\dsh-badge.ps1 -StateFile "$env:TEMP\badge.json" -Heartbeat "$env:TEMP\badge.hb" -Seconds 90
```

字段都是可选的：

| 字段 | 说明 |
| --- | --- |
| `title` | 标题行 |
| `detail` | 第二行，建议一句话说明当前动作 |
| `step` / `total` | 显示「第 2 / 5 步」并画进度条 |
| `tone` | `busy`（蓝）/ `waiting`（橙）/ `error`（红）/ `done`（绿） |

`done` 之后建议留几秒再停角标，让人看见结果是绿的。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Text` | `DSH 正在操作电脑` | 标题 |
| `-Detail` | 空 | 副标题 |
| `-Seconds` | `180` | 自动隐藏秒数；心跳模式下是「静默多久算死」 |
| `-Heartbeat` | 空 | 心跳文件路径 |
| `-StateFile` | 空 | 状态 JSON 路径，给了才轮询 |
| `-CancelFile` | 空 | 配合 `-Clickable`，点 × 时写入这个文件 |
| `-Clickable` | 关 | 关掉点击穿透，整个角标可点 |
| `-Stop` | — | 停掉已在跑的角标 |
| `-Captureable` | 关 | 允许出现在截图和录屏里（只用于自检） |
| `-Anchor` | `BottomRight` | `BottomRight` / `BottomLeft` / `TopRight` / `TopLeft` / `BottomCenter` |
| `-Monitor` | `0` | 显示器序号，0 是主屏 |
| `-Opacity` | `0.92` | 整体不透明度 |
| `-Accent` | `#00D4FF` | 主色（标题点、进度条、边框） |
| `-Lang` | `zh` | `zh` / `en` |

## 取消

```powershell
powershell -ExecutionPolicy Bypass -File .\dsh-badge.ps1 -Clickable -CancelFile "$env:TEMP\badge.cancel" -Seconds 600
```

点了 × 之后，`badge.cancel` 会出现。agent 在每个步骤边界检查这个文件，发现就停手并清理。

注意：`-Clickable` 会关掉点击穿透，那 392×96 的小区域会挡住下面的点击。默认不加。

## 坑

- **文件要 UTF-8 BOM**，否则 Windows PowerShell 5.1 读中文会乱码。
- **进程用 pid 文件（`%TEMP%\dsh-badge.pid`）记录，不扫命令行**。早期版本靠命令行匹配，结果会把「用 Start-Process 拉起角标」的启动器一起杀掉；现在只杀 pid 文件里那个、且命令行确实对得上的进程。pid 文件丢了就手动 `Get-Process powershell` 清一下。
- **高 DPI 缩放下窗口会被系统再乘一次缩放**。这个脚本已经按 `GetDpiForWindow` 反算，150% 缩放下位置正确；自己改定位逻辑时记得处理这一层，不然角标会跑到屏幕外。
- **默认不进截图**是有意的。要自检画面加 `-Captureable`。
- 依赖 .NET Framework 的 WPF，Windows 10 / 11 自带，不需要额外安装。

## 英文说明 / English

A tiny always-on-top status badge for desktop agents on Windows. It tells the person what the agent is doing *right now*, so they don't mistake a working agent for a stuck one.

- Click-through by default, excluded from screenshots/recordings by default
- Live-updating state from a JSON file (title, detail, step counter, tone)
- Heartbeat mode: disappears by itself when the agent stops touching the heartbeat file
- Optional cancel button that writes a marker file the agent can poll

Requirements: Windows 10/11, Windows PowerShell 5.1 (WPF). MIT licensed.

## License

MIT

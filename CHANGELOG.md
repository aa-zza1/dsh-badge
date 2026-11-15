# Changelog

## 2.0.0 — 2026-11-15

- 新增 `-StateFile`：轮询 JSON，标题 / 副标题 / 步骤 / 色调实时更新，不用重启
- 新增步骤计数与进度条（`step` / `total`）
- 新增 `-Clickable` + `-CancelFile`：点 × 写入取消标记，agent 可据此停手
- 新增 `-Anchor` / `-Monitor` / `-Opacity` / `-Accent` / `-Lang`
- 修复高 DPI（150%）下角标被二次缩放、跑到屏幕外的问题：按 `GetDpiForWindow` 反算坐标
- 状态色：`busy` / `waiting` / `error` / `done`

## 1.0.0 — 2026-10

- 首版：置顶、点击穿透、不进截图、心跳自灭

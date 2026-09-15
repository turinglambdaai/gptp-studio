# 截图 / Screenshots

自动化截屏在本会话（无屏幕录制权限）不可用。明天验收时：

1. 启动应用（或 `dist/gPTP Studio.app`）：
   `racket main.rkt --simulator`
2. 逐页切换（总览会积累约 1 分钟曲线数据后更好看）
3. `Cmd+Shift+4`（或整窗 `Cmd+Shift+4` 后按空格）截取六页 + 报文详情抽屉
4. 保存到本目录（建议命名 `01-overview.png` … `06-runtime.png`）
5. README 引用：在两份 README 的 Highlights 前插入画廊

> 也可以在有录屏权限的终端跑 `scripts/screenshot.sh <窗口标题>`（通过 osascript 取 window id 后 `screencapture -l`）。

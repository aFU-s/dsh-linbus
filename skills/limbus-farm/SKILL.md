---
name: limbus-farm
description: 半自动刷《边狱巴士》采光 STAGE 10（经验本 / 纺锤灯泡本）：用户说连续刷 n 次就按 n 设置「连续进行」并托管；先确认模块消耗。
when-to-use: 用户说“连续刷 n 次经验本 / 纺锤本 / 灯泡本”时。
---

# 边狱巴士 · 半自动连续刷 STAGE 10

支持**经验采光**和**纺锤（灯泡）采光**的 STAGE 10；一次进入按「连续进行 ×n」打 n 波。不做每日排班、不做镜牢/活动。

## 成本纪律（先看）

- 能用 farm 就不要逐步手动：一次 farm 只花 1–3 次模型往返；逐步截图 40+ 次。
- 不要每步 `read_image`；只在失败/未知界面看一张截图。
- 一次会话只跑一个任务；跑完结束，下一个任务**新开会话**（避免历史越滚越贵）。
- 不粘贴长日志/报告全文；只报摘要。
- `limbus_farm_start` 10 秒没 status：用 `tool-pwsh` 后台 fallback 一次，不要退回逐步手动。

## 0. 前置

- 游戏已登录，停在**主界面**（能看到底部「驾驶席 / 采光」）。
- 标题页（START / FACE THE SIN）不支持；先让用户手动进游戏。
- 窗口 16:9、未最小化、未锁屏。
- **选人页先选好队伍**：farm 不会自动选人；空队伍会返回 `team-empty` 并停止，避免把预设编队点乱。

## 1. 次数规则

- `n ≤ 0`：向用户解释“次数必须大于 0”，**不启动、不消耗模块**；
- `0 < n ≤ 10`：按 n 设置「连续进行 ×n」；经验本每场 3 模块，纺锤本每场 **2** 模块；
- `n > 10`：先说明“最多连续 10 次”，按 10 次执行（经验 30 / 纺锤 20 模块）。

用户确认后再继续。不要替用户默认确认。

## 2. 启动

调用（经验本 / 纺锤本二选一）：

```
limbus_farm_start({ kind: "exp",     runs: n, confirm: true })
limbus_farm_start({ kind: "spindle", runs: n, confirm: true })
```

farm 会按 kind 选关：**经验本选最右 STAGE 10**；**纺锤本选最左的每日开放副本**（每天开放的本会自动排到最左），再在选关弹窗里选**最下面 Lv60「精灵提灯」**（资源最多）。连续进行在弹窗里设置。`n>10` 时工具会封顶 10 并在返回文本里说明。

**队伍**：只检查选人页「开始战斗」是否已亮着；亮着就直接开打，**不点任何卡片**；没队伍就返回 `team-empty` 停止，不自动选人。

## 3. 轮询

每 60 秒查一次：

```
limbus_farm_status({ runId: "<runId>", waitSeconds: 60 })
```

- `state` 为 `starting` / `running`：继续等；
- `done` 变成 n：n 波全部完成（连续作战只有最后才出 VICTORY）；
- `success`：n 波全部完成，读 `report` 汇总；
- `failed` / `partial`：停止，按第 4 节处理。

不要每一步都截图；只在失败或用户要看时截图。

## 4. 失败处理

1. `limbus_farm_stop({ runId })`（如果还在跑）。
2. `limbus_screenshot({ note: "farm-failed" })` + `read_image`，确认卡在哪。
3. 向用户报告：完成几波、消耗多少模块、错误码（`battle-not-victory` / `battle-timeout` / `left-battle` / `team-empty` / `hard-timeout` / `splash-stuck` / `result-stuck` / `window-not-found` / `not-16-9`）、截图路径。
4. 不要自动重试；等用户决定。

## 5. 汇报

结束后用 3–5 行汇报：

- 目标 n 波、是否全部完成；
- 总回合数（`report.turns`）；
- 消耗模块数（经验 n×3；纺锤 n×2；失败/中止按实际说明）；
- 异常/截图路径（如有）。

## 6. 已知坑（2026-11-03 实测）

- **截图有 1–2 帧延迟**：点击后至少等 500ms 再看；不要凭一张截图判断“没点上”就重复点。
- **自动战斗不是一键到底**：每回合 `P`（自动配牌）→ 等 700ms → `Enter`（开打）。右下 START 球有时不响应，统一用 Enter。
- **连续进行控件**：经验本点卡片主体打开步进器；纺锤本先点每日卡「进入」打开选关弹窗，再点弹窗顶部箭头打开步进器；绿色 `+` 在步进器右侧。farm 已按两种布局分别封装。
- **纺锤本选关**：每日开放副本固定排在最左；弹窗里选**最下面 Lv60「精灵提灯」**（资源最多），点它的「进入」（y≈0.62，别点到下面）。
- **VICTORY 大动画不是结算页**：连续作战只有**全部打完**才出 VICTORY；中途会自动进入下一场，不需要重复点「进入 / 开始战斗」。farm 现在要求战斗 HUD 消失 + 连续两帧都在才判 VICTORY，开局黄牌/过场不会再误报 `splash-stuck`。
- **结束托管会杀后台进程**：`limbus_farm_stop` 不只写 stop，还会杀掉 farm PowerShell；开始新托管也会先清理旧进程，避免它继续按 `P`/`Enter`。
- **`limbus_farm_start` 10 秒内没有 status.json**：说明运行中的 DSH 还是旧插件代码（没有 `farm.log`）。先重启 DSH；紧急时可直接用后台任务跑：
  `powershell -NoProfile -ExecutionPolicy Bypass -File <插件目录>\scripts\limbus.ps1 -Action farm -Runs n -Kind exp -RunId <id> -RunDir <dir>`
  用 `run_in_background` 启动，然后轮询 `<dir>\status.json`。

## 7. 边界

- 不抽卡、不买商店、不换体力；
- 不点「跳过战斗」（消耗 6 模块）；
- 不修改游戏文件、不注入；
- 自动化有封号风险，建议小号。

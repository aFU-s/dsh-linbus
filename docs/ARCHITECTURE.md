# 为什么这样拆：对照 dsh-game-daily

`dsh-game-daily` 的分层是：

```
设置页（client.js） → Host API（index.js） → 排班/计划任务 → headless DSH 会话 → 技能/MCP 操作游戏 → report.json → 对账/通知
```

它的关键洞察是：**插件本身不碰游戏**。插件只做配置、排班、报告台；
真正“怎么点”的部分交给技能和 MCP。

`dsh-limbus` 按同一思路拆，但先做最小闭环：

| dsh-game-daily | dsh-limbus（当前） | 说明 |
|---|---|---|
| `client.js` 设置页 | 暂无 | 先用对话驱动；P2 再加 `settings.section` |
| Host API `/api/game-daily/*` | `limbus_*` 工具（10 个） | 工具就是 Host 能力，agent 直接调 |
| `game-daily-*` 技能 | `limbus-daily` 技能 | 流程、坐标、安全边界、报告约定 |
| BetterGI / bettergi-mcp / computer-use | `scripts/limbus.ps1` | 截图 + 点击 + 按键的 Windows 原语 |
| Windows 计划任务 | 暂无（P2） | 现在由用户/agent 手动触发 |
| headless DSH 会话 | 当前会话 | P2 再接 headless |
| `report.json` + reconcile | `runs/<id>/report.json`（技能写） | 同一份报告契约 |
| `keep-foreground.ps1` | `limbus_focus` | 需要时手动置前 |

## 为什么不是“插件里写死一套点击脚本”

固定脚本在 UI 更新、加载慢、弹窗出现时会盲点，风险比 agent 看截图高。
所以当前把“判断”留给 agent，“执行”留给工具；技能只约束流程与安全边界。
等流程稳定后，再把高频、确定的片段（进本、选人）下沉成高层工具或本地状态机。

## 分阶段

- **P1（已完成）**：10 个窗口/托管工具 + `limbus-daily` / `limbus-farm` 技能 + 经验本与纺锤本实机验证。
- **P2**：设置页（开关/场次/演练模式）、DSH 排班或 Windows 计划任务、报告对账。
- **P3**：headless 运行、失败重试、镜牢/邮件等更多日常。

## 与 game-daily 的差异

- game-daily 是“多游戏编排”，本插件先做单游戏；
- game-daily 的“手”是第三方工具（BetterGI/一条龙），本插件的“手”是自己实现的
  Windows 原语（因为边狱巴士没有现成 MCP）；
- game-daily 用技能 + 提权助手，本插件用相对坐标 + agent 视觉，不依赖 UIA
  （Unity 游戏通常没有可用的 UIA 树）。

# Changelog

本项目遵循语义化版本。日期为本地时间。

## 0.2.1 — 2026-11-18

- 包内 `limbus-farm` / `limbus-daily` 技能改为由插件自动注册，安装后无需手动复制到 `~/.dsh/skills`；
- 根 Host 行关闭技能注册，只有「边狱巴士」preset 行注册技能，避免重复；
- README 增加 DSH **Plugins → Add plugin** 的 GitHub URL 安装方式。

## 0.2.0 — 2026-11-18

- 将 `dsh-limbus-control` 与 `dsh-limbus-mode` 合并为一个包 `dsh-limbus`；
- 一个 `cordis.patch.yml` 同时提供 Host 工具行和「边狱巴士」agent preset；
- 新增 `limbus_farm_*` 半自动托管工具，支持 `kind: "exp" | "spindle"` 与连续进行 n 次；
- 经验本固定 STAGE 10（3 模块/场），纺锤本固定每日副本 Lv60 精灵提灯（2 模块/场）；
- 增加 stop 标记、后台进程清理、单实例与超时保护；
- 增加 locale / icon / LICENSE / README / 架构文档。

## 0.1.0 — 2026-10-28

- 初版 `dsh-limbus-control`：窗口截图、相对坐标点击、按键、置前、等待；
- 初版 `dsh-limbus-mode`：只挂 Limbus 工具的 agent preset；
- 完成一次经验采光 STAGE 10 实机验证（7 回合，VICTORY，3 模块）。

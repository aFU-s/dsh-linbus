# dsh-limbus

给 [DeepSeek Harness（DSH）](https://github.com/deepseek-ai) 用的《边狱巴士》半自动托管插件。

一个包同时提供 **Host 工具**和**「边狱巴士」agent preset**：agent 能看游戏窗口、点击、按键，并能按「连续进行 n 次」的采光托管流程刷经验本 / 纺锤本。

> 项目地址：<https://github.com/aFU-s/dsh-linbus>
>
> 包名是 `dsh-limbus`，仓库名是 `dsh-linbus`，两者是同一个项目。

## 功能

- **窗口工具**：状态、窗口列表、截图、相对坐标点击、按键、置前、等待；
- **半自动托管**：`limbus_farm_start / status / stop`；
- **经验本**：采光最右 **STAGE 10**，每场消耗 **3** 个模块；
- **纺锤本（灯泡本）**：采光 → 纺锤 → 最左每日副本 → 弹窗最下面 **Lv60 精灵提灯**，每场消耗 **2** 个模块；
- **连续进行 n 次**：`0 < n ≤ 10` 按 n；`n > 10` 按 10；`n ≤ 0` 不启动；
- **安全停手**：写 stop 标记并杀掉后台 farm 进程，避免继续按 `P` / `Enter`；
- **「边狱巴士」preset**：只加载本插件、文件工具、技能工具和一段托管 persona。

## 环境要求

- Windows 10 / 11；
- DSH Web profile（`dsh web`）；
- 游戏窗口化 / 无边框窗口，客户区 16:9（脚本按 1920×1080 实机标定，其他 16:9 分辨率会按比例换算）；
- 游戏已登录，停在主界面；
- 建议小号，自动化输入有封号风险。

## 安装

### 方式一：DSH 的「添加插件」（推荐）

在 DSH 的 **Plugins → Add plugin** 里粘贴：

```text
https://github.com/aFU-s/dsh-linbus
```

安装并启用 `dsh-limbus` 后**重启 DSH**。新建会话时模式选择器里会出现「边狱巴士」。

- 这个仓库根目录就是完整的 DSH bundle；
- 安装时 DSH 会把它加入 profile 的 `dsh.profile.bundles`；
- 包内的 `limbus-farm` / `limbus-daily` 技能会由插件自动注册，**不需要手动复制**。

### 方式二：本地 clone 后链接

```powershell
git clone https://github.com/aFU-s/dsh-linbus.git
cd dsh-linbus
dsh plugin --profile web add "link:$(Get-Location)"
```

确认 profile 的 `dsh.profile.bundles` 里有 `dsh-limbus`，然后重启 DSH。

### 方式三：交给 agent 安装

如果当前 DSH 有 `plugin_manager` 工具：

```text
plugin_manager action=install_bundle target="https://github.com/aFU-s/dsh-linbus"
```

## 使用

1. 启动游戏，登录，停在主界面；
2. 新建会话，模式选「**边狱巴士**」；
3. 直接说需求，例如：
   - `连续刷经验10，3次`
   - `连续刷纺锤本（灯泡本），2次`
4. 助手会先确认模块消耗（经验 `3n` / 纺锤 `2n`），确认后才启动；
5. farm 会把采光页的「连续进行」设为 n，然后只进入一次；
6. 运行中用 `limbus_farm_status({ waitSeconds: 60 })` 轮询；
7. 需要中止时调用 `limbus_farm_stop`。

> 不要自己重复点「进入 / 开始战斗」；连续进行模式下，中间场次会自动开始，全部打完才出 `VICTORY`。

### 选关与队伍

| 项目 | 经验本 | 纺锤本 |
|---|---|---|
| 入口 | 采光最右 STAGE 10 | 采光 → 纺锤 → 最左每日副本 |
| 关卡 | STAGE 10 | 弹窗最下面 Lv60「精灵提灯」 |
| 单场模块 | 3 | 2 |
| 连续 n 次消耗 | 3n | 2n |

- 队伍必须在选人页**预先选好**；farm 不自动点人格；
- 开始战斗按钮没亮时，farm 会以 `team-empty` 停止，不会盲点；
- `n > 10` 时最多按 10 次执行。

## 工具

| 工具 | 作用 |
|---|---|
| `limbus_status` | 窗口是否存在、客户区尺寸、是否前台/最小化 |
| `limbus_windows` | 列出可见窗口标题（排查标题不匹配） |
| `limbus_screenshot` | 抓客户区 PNG，返回路径；再用 `read_image` 查看 |
| `limbus_click` | 按相对坐标点击（0~1，自动换算像素） |
| `limbus_key` | 发送按键：`a-z`、`0-9`、`enter/esc/space/tab/up/down/left/right/f1-f12` |
| `limbus_focus` | 把游戏窗口置前（含最小化恢复） |
| `limbus_wait` | 等待 0~30000 ms |
| `limbus_farm_start` | 启动半自动托管；`kind` 为 `exp` / `spindle`；必须 `confirm: true` |
| `limbus_farm_status` | 查询进度/报告，可传 `waitSeconds` 轮询 |
| `limbus_farm_stop` | 写 stop 标记并杀掉后台 farm 进程 |

## 配置

`cordis.patch.yml` 里的 Host 行默认配置：

```yaml
- id: limbus-control
  name: dsh-limbus
  config:
    windowTitle: Limbus
    processName: LimbusCompany
```

- `windowTitle`：标题包含该子串即命中（不区分大小写）；
- `processName`：进程名包含该子串也命中，作为标题被改过时的兜底；
- 两个都匹配时取客户区面积最大的窗口。

要覆盖配置，请在 profile 的 `cordis.patch.yml` 里按同一 `id` 写 `config`，不要改包内文件。

## 实现结构

```text
agent（模型）
  │  limbus_* 工具
  ▼
index.js（Host 插件，纯 Node，无第三方依赖）
  │  spawn powershell.exe -File scripts/limbus.ps1 -Action ...
  ▼
PowerShell 后端（user32 / gdi32 P/Invoke）
  ├─ FindWindow：标题/进程匹配
  ├─ CopyFromScreen：截客户区
  ├─ SetForegroundWindow + AttachThreadInput：置前
  ├─ SetCursorPos + mouse_event：点击
  └─ keybd_event：按键
```

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 安全边界

- 只操作标题含 `Limbus` / 进程名含 `LimbusCompany` 的窗口；
- 不读内存、不注入 DLL、不改游戏文件；
- 输入走 Windows 的 `mouse_event` / `keybd_event`，和真实鼠标键盘同一层；
- 点击/按键前会先置前并确认窗口；
- 截图可能包含账号信息，分享前请打码；
- **自动化输入有封号风险，后果自负；建议先在小号验证。**

## 开发

```powershell
node --check index.js
node test/smoke.mjs
```

只做窗口预检、不点击、不消耗模块：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\limbus.ps1 -Action farm -Runs 0 -Kind exp `
  -RunDir "$env:TEMP\limbus-farm-check"
```

改 `index.js` 后需要重启 DSH；改 `scripts/limbus.ps1` 不需要重启。
如果改了脚本里的 C#，把 `LimbusWin-vN.dll` 的版本号加一，避免命中旧缓存。

## 许可

[MIT](LICENSE)

## 免责声明

本项目仅用于个人学习与单机自动化实验，与 Project Moon 无关。使用本工具可能违反游戏服务条款，账号风险由使用者自行承担。

/**
 * dsh-limbus — host-side plugin + agent preset for DeepSeek Harness.
 *
 * 它给 agent 一双“眼睛和手”，作用域只有《边狱巴士》的窗口：
 *   - limbus_status      窗口是否存在、客户区尺寸、是否前台
 *   - limbus_windows     列出当前可见窗口（调试窗口标题用）
 *   - limbus_screenshot  抓客户区 PNG，返回路径（再用 read_image 看）
 *   - limbus_click       按相对坐标点击（0~1，自动换算像素）
 *   - limbus_key         发一个按键（字母/数字/enter/esc/space/tab/f1..f12）
 *   - limbus_focus       把游戏窗口拉到前台
 *   - limbus_wait        等待若干毫秒
 *
 * 设计取舍：
 *   - 不依赖 @deepseek-ai/dsh-tools：直接交给 ctx.tools.register() 一个
 *     合法的原始 JSON Schema 工具定义，避免外部 link 安装时的模块解析问题。
 *   - 不重写视觉：截图交给 agent 侧的 read_image；插件只做“抓屏/输入”这类
 *     Windows 原语，全部放在 PowerShell 后端里（系统自带，无需 npm 依赖）。
 *   - 默认只匹配标题含 “Limbus” 或进程名含 “LimbusCompany” 的窗口，
 *     不会误点别的程序；所有点击/按键前都会先确认窗口在前台。
 */
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const execFileP = promisify(execFile)
const HERE = path.dirname(fileURLToPath(import.meta.url))
const SCRIPT = path.join(HERE, 'scripts', 'limbus.ps1')
const POWERSHELL = 'powershell.exe'
const MARKER = '@@RESULT@@'
const FARM_ROOT = process.env.LOCALAPPDATA
  ? path.join(process.env.LOCALAPPDATA, 'dsh-limbus-control', 'farm')
  : path.join(os.tmpdir(), 'dsh-limbus-control', 'farm')
const FARM_GLOBAL_STOP = path.join(path.dirname(FARM_ROOT), 'farm.stop')
const farmChildren = new Set()

/** 杀掉所有正在跑的 farm PowerShell 进程，避免旧托管继续按 P/Enter。 */
async function killFarmProcesses() {
  const cmd = "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'limbus\\.ps1' -and $_.CommandLine -match 'farm' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
  try {
    await execFileP(POWERSHELL, [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd,
    ], { windowsHide: true, timeout: 10000 })
  } catch { /* best effort */ }
  for (const child of farmChildren) {
    try { child.kill() } catch { /* ignore */ }
  }
  farmChildren.clear()
}

export const name = 'limbus-control'
export const inject = ['tools']

const DEFAULTS = {
  /** 窗口标题包含这个子串即命中（不区分大小写）。 */
  windowTitle: 'Limbus',
  /** 进程名包含这个子串也命中（给标题被改过的客户端兜底）。 */
  processName: 'LimbusCompany',
  /** 截图目录；空 = 系统临时目录下的 dsh-limbus-control/shots。 */
  shotDir: '',
}

export function resolveConfig(input = {}) {
  const cfg = { ...DEFAULTS, ...(input && typeof input === 'object' ? input : {}) }
  cfg.windowTitle = String(cfg.windowTitle || DEFAULTS.windowTitle).trim()
  cfg.processName = String(cfg.processName ?? DEFAULTS.processName).trim()
  cfg.shotDir = String(cfg.shotDir || '').trim()
    || path.join(os.tmpdir(), 'dsh-limbus-control', 'shots')
  return cfg
}

/** 调一次 PowerShell 后端，取回最后一行 @@RESULT@@ JSON。 */
async function runPowerShell(action, params, signal, timeout = 30000) {
  const args = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', SCRIPT,
    '-Action', action,
  ]
  const push = (flag, value) => {
    if (value === undefined || value === null || value === '') return
    args.push(flag, String(value))
  }
  push('-WindowTitle', params.windowTitle)
  push('-ProcessName', params.processName)
  push('-Out', params.out)
  push('-Key', params.key)
  push('-Button', params.button)
  if (params.rx !== undefined) push('-RX', params.rx)
  if (params.ry !== undefined) push('-RY', params.ry)
  if (params.waitMs !== undefined) push('-WaitMs', params.waitMs)
  if (params.double === true) args.push('-Double')

  let stdout = ''
  try {
    const r = await execFileP(POWERSHELL, args, {
      windowsHide: true,
      timeout,
      maxBuffer: 16 * 1024 * 1024,
      encoding: 'utf8',
      signal,
    })
    stdout = String(r.stdout || '')
  } catch (error) {
    const detail = error && error.stderr ? String(error.stderr).trim() : ''
    throw new Error(`PowerShell 调用失败：${(error && error.message) || error}${detail ? `\n${detail}` : ''}`)
  }

  const lines = stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
  const line = [...lines].reverse().find((item) => item.startsWith(MARKER))
  if (!line) throw new Error(`PowerShell 没有返回结果：${stdout.slice(0, 800)}`)
  try {
    return JSON.parse(line.slice(MARKER.length))
  } catch (error) {
    throw new Error(`PowerShell 返回的 JSON 无法解析：${line.slice(0, 800)}`)
  }
}

const WINDOW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    hwnd: { type: 'number' },
    title: { type: 'string' },
    process: { type: 'string' },
    pid: { type: 'number' },
    width: { type: 'number' },
    height: { type: 'number' },
    screenX: { type: 'number' },
    screenY: { type: 'number' },
    foreground: { type: 'boolean' },
    minimized: { type: 'boolean' },
  },
}

const OUTPUT = {
  schema: {
    type: 'object',
    additionalProperties: false,
    required: ['ok', 'text'],
    properties: {
      ok: { type: 'boolean' },
      text: { type: 'string' },
      path: { type: 'string' },
      width: { type: 'number' },
      height: { type: 'number' },
      x: { type: 'number' },
      y: { type: 'number' },
      foreground: { type: 'boolean' },
      window: WINDOW_SCHEMA,
      runId: { type: 'string' },
      state: { type: 'string' },
      done: { type: 'number' },
      runs: { type: 'number' },
      kind: { type: 'string' },
      costPerRun: { type: 'number' },
      cost: { type: 'number' },
      notes: { type: 'string' },
      statusPath: { type: 'string' },
      report: { type: 'object', additionalProperties: true },
    },
  },
  render: (_args, value) => [{ type: 'text', text: value.text }],
}

function describeWindow(window) {
  if (!window) return '窗口信息不可用'
  const bits = [
    `标题「${window.title || '?'}」`,
    `进程 ${window.process || '?'} (pid ${window.pid ?? '?'})`,
    `客户区 ${window.width}x${window.height}`,
    window.foreground ? '前台' : '不在前台',
  ]
  if (window.minimized) bits.push('已最小化')
  return bits.join('，')
}

function notFound(result) {
  const extra = Array.isArray(result.windows) && result.windows.length
    ? `\n当前可见窗口（前 10 个）：\n${result.windows.slice(0, 10).map((t) => `- ${t}`).join('\n')}`
    : ''
  return {
    ok: false,
    text: `没找到游戏窗口（${result.error || 'window-not-found'}）。请先启动《边狱巴士》，或检查 windowTitle 配置。${extra}`,
  }
}

function readJsonFile(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''))
  } catch {
    return null
  }
}

function listFarmRuns() {
  try {
    return fs.readdirSync(FARM_ROOT, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort()
      .reverse()
  } catch {
    return []
  }
}

function latestFarmRun() {
  return listFarmRuns()
    .find((name) => fs.existsSync(path.join(FARM_ROOT, name, 'status.json'))) || ''
}

const clampRelative = (value, label) => {
  const num = Number(value)
  if (!Number.isFinite(num) || num < 0 || num > 1) {
    throw new Error(`${label} 必须是 0~1 之间的数字（相对客户区的比例）`)
  }
  return num
}

const KEY_RE = /^(?:[a-z0-9]|enter|return|esc|escape|space|tab|backspace|up|down|left|right|f(?:[1-9]|1[0-2]))$/i

export function apply(ctx, rawConfig) {
  const cfg = resolveConfig(rawConfig)
  const tools = ctx && ctx.tools
  if (!tools || typeof tools.register !== 'function') return

  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => {
      try { fs.rmSync(FARM_GLOBAL_STOP, { force: true }) } catch { /* ignore */ }
      void killFarmProcesses()
    })
  }
  // 插件加载时先清掉上一次 DSH 进程遗留的 farm，避免它继续按 P/Enter。
  void killFarmProcesses()

  const base = () => ({ windowTitle: cfg.windowTitle, processName: cfg.processName })

  // ---------------------------------------------------------------- 状态
  tools.register({
    name: 'limbus_status',
    description:
      '查看《边狱巴士》窗口状态：是否找到窗口、客户区尺寸、是否在前台、是否最小化。'
      + '在截图或点击之前先用它确认游戏窗口已打开。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: OUTPUT,
    async execute(_args, exec) {
      const result = await runPowerShell('info', base(), exec && exec.signal, 15000)
      if (!result.ok) return notFound(result)
      return {
        ok: true,
        window: result.window,
        foreground: result.window.foreground,
        width: result.window.width,
        height: result.window.height,
        text: `窗口已找到：${describeWindow(result.window)}`,
      }
    },
  })

  // ---------------------------------------------------------------- 列窗口
  tools.register({
    name: 'limbus_windows',
    description:
      '列出当前可见的顶层窗口标题，用于排查“窗口标题不匹配”的问题。'
      + '只读，不会激活或点击任何窗口。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: OUTPUT,
    async execute(_args, exec) {
      const result = await runPowerShell('windows', base(), exec && exec.signal, 15000)
      if (!result.ok) return { ok: false, text: `列窗口失败：${result.error || 'unknown'}` }
      const list = Array.isArray(result.windows) ? result.windows : []
      return {
        ok: true,
        text: list.length ? `可见窗口：\n${list.map((t) => `- ${t}`).join('\n')}` : '没有可见窗口',
      }
    },
  })

  // ---------------------------------------------------------------- 截图
  tools.register({
    name: 'limbus_screenshot',
    description:
      '抓取《边狱巴士》客户区并保存为 PNG，返回文件路径。'
      + '拿到路径后调用 read_image 查看这张图，再决定下一步点哪里。'
      + '截图前会把游戏窗口拉到前台（客户区必须可见，不能最小化）。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        note: { type: 'string', description: '可选：给这张截图起个短标签，方便回看' },
      },
    },
    output: OUTPUT,
    async execute(args, exec) {
      fs.mkdirSync(cfg.shotDir, { recursive: true })
      const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+$/, '').replace('T', '-')
      const safe = String((args && args.note) || 'shot').replace(/[^\w.-]+/g, '-').slice(0, 40)
      const file = path.join(cfg.shotDir, `limbus-${stamp}-${safe}.png`)

      const result = await runPowerShell(
        'shot',
        { ...base(), out: file },
        exec && exec.signal,
        30000,
      )
      if (!result.ok) {
        return { ok: false, text: `截图失败：${result.error || 'unknown'}（窗口是否最小化/被锁屏？）` }
      }
      return {
        ok: true,
        path: result.path || file,
        width: result.width,
        height: result.height,
        window: result.window,
        foreground: result.foreground,
        text: `已截图（${result.width}x${result.height}）→ ${result.path || file}\n`
          + '用 read_image 打开这个路径查看画面。',
      }
    },
  })

  // ---------------------------------------------------------------- 点击
  tools.register({
    name: 'limbus_click',
    description:
      '在《边狱巴士》客户区按相对坐标点击。x/y 取 0~1（左上角 0,0，右下角 1,1），'
      + '插件会按当前客户区尺寸换算成像素，并先把游戏窗口拉到前台。'
      + '点击前请先截图确认目标位置，避免误点。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['x', 'y'],
      properties: {
        x: { type: 'number', minimum: 0, maximum: 1, description: '相对客户区宽度的比例' },
        y: { type: 'number', minimum: 0, maximum: 1, description: '相对客户区高度的比例' },
        button: { type: 'string', enum: ['left', 'right'], description: '默认 left' },
        double: { type: 'boolean', description: '是否双击' },
      },
    },
    output: OUTPUT,
    async execute(args, exec) {
      const rx = clampRelative(args && args.x, 'x')
      const ry = clampRelative(args && args.y, 'y')
      const button = args && args.button === 'right' ? 'right' : 'left'
      const result = await runPowerShell(
        'click',
        { ...base(), rx, ry, button, double: !!(args && args.double) },
        exec && exec.signal,
        20000,
      )
      if (!result.ok) {
        return { ok: false, text: `点击失败：${result.error || 'unknown'}（窗口不在前台或被遮挡）` }
      }
      return {
        ok: true,
        x: result.x,
        y: result.y,
        width: result.width,
        height: result.height,
        foreground: result.foreground,
        text: `已点击 (${result.x}, ${result.y}) 像素，客户区 ${result.width}x${result.height}`
          + `${result.foreground ? '' : '；警告：点击后窗口不在前台'}`,
      }
    },
  })

  // ---------------------------------------------------------------- 按键
  tools.register({
    name: 'limbus_key',
    description:
      '向《边狱巴士》发送一个按键：字母 a-z、数字 0-9，或 enter/esc/space/tab/'
      + 'backspace/up/down/left/right/f1-f12。会先把游戏窗口拉到前台。'
      + '（游戏里的自动战斗键请按当前版本自行确认，常见是 P。）',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['key'],
      properties: {
        key: { type: 'string', description: '例如 p、enter、esc、space、f1' },
      },
    },
    output: OUTPUT,
    async execute(args, exec) {
      const key = String((args && args.key) || '').trim()
      if (!KEY_RE.test(key)) throw new Error(`不支持的按键：${key || '(空)'}`)
      const result = await runPowerShell(
        'key',
        { ...base(), key },
        exec && exec.signal,
        15000,
      )
      if (!result.ok) return { ok: false, text: `按键失败：${result.error || 'unknown'}` }
      return { ok: true, text: `已发送按键 ${key.toUpperCase()}` }
    },
  })

  // ---------------------------------------------------------------- 置前
  tools.register({
    name: 'limbus_focus',
    description: '把《边狱巴士》窗口恢复到前台（最小化会先还原）。只激活窗口，不点击。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: OUTPUT,
    async execute(_args, exec) {
      const result = await runPowerShell('focus', base(), exec && exec.signal, 15000)
      if (!result.ok) return { ok: false, text: `置前失败：${result.error || 'unknown'}` }
      return { ok: true, text: `已置前：${describeWindow(result.window)}` }
    },
  })

  // ---------------------------------------------------------------- 等待
  tools.register({
    name: 'limbus_wait',
    description: '等待指定毫秒数（0~30000），用于等动画、加载或战斗结算。不会操作游戏。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['ms'],
      properties: { ms: { type: 'number', minimum: 0, maximum: 30000 } },
    },
    output: OUTPUT,
    async execute(args, exec) {
      const ms = Math.max(0, Math.min(30000, Math.round(Number(args && args.ms) || 0)))
      await new Promise((resolve, reject) => {
        const timer = setTimeout(resolve, ms)
        const signal = exec && exec.signal
        if (signal) {
          const onAbort = () => {
            clearTimeout(timer)
            reject(new Error('已取消'))
          }
          if (signal.aborted) onAbort()
          else signal.addEventListener('abort', onAbort, { once: true })
        }
      })
      return { ok: true, text: `已等待 ${ms} ms` }
    },
  })

  // ---------------------------------------------------------------- 半自动托管
  tools.register({
    name: 'limbus_farm_start',
    description:
      '半自动刷《边狱巴士》采光（经验本 STAGE 10 / 纺锤灯泡本 Lv60）：把「连续进行」设为 n 次后打一次连续战。'
      + '0<n≤10 按 n；n>10 说明后按 10；n≤0 不启动。单场消耗：经验 3 模块、纺锤 2 模块；'
      + '开始前必须让用户确认总消耗；confirm=true 才启动。游戏必须已登录并停在主界面。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['runs', 'confirm'],
      properties: {
        kind: {
          type: 'string',
          enum: ['exp', 'spindle'],
          description: 'exp=经验本；spindle=纺锤（灯泡本）；默认 exp',
        },
        runs: {
          type: 'integer',
          description: '连续次数 n；0<n≤10 按 n，n>10 按 10，n≤0 不刷',
        },
        confirm: { type: 'boolean', description: '确认消耗 经验 n×3 / 纺锤 n×2 个模块' },
      },
    },
    output: OUTPUT,
    async execute(args, exec) {
      const runsInput = Number(args && args.runs)
      if (!Number.isInteger(runsInput)) {
        throw new Error('runs 必须是整数')
      }
      const kind = args && args.kind === 'spindle' ? 'spindle' : 'exp'
      const kindLabel = kind === 'spindle' ? '纺锤（灯泡）' : '经验'
      const costPerRun = kind === 'spindle' ? 2 : 3
      if (runsInput <= 0) {
        return {
          ok: false,
          text: `未启动：次数必须大于 0（收到 ${runsInput}）。本次不刷，不消耗模块。`,
        }
      }
      const runs = runsInput > 10 ? 10 : runsInput
      const totalCost = runs * costPerRun
      const notice = runsInput > 10
        ? `最多连续 10 次，本次按 10 次执行（收到 ${runsInput}）。\n`
        : ''
      if (!args || args.confirm !== true) {
        return {
          ok: false,
          text: `${notice}未启动：${kindLabel}采光，连续 ${runs} 次，单场 ${costPerRun} 模块，预计消耗 ${totalCost} 个模块。确认后传 confirm:true 再调用。`,
        }
      }

      await killFarmProcesses()
      try { fs.rmSync(FARM_GLOBAL_STOP, { force: true }) } catch { /* ignore */ }

      const pre = await runPowerShell('info', base(), exec && exec.signal, 15000)
      if (!pre.ok) return notFound(pre)

      fs.mkdirSync(FARM_ROOT, { recursive: true })
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)
      const runId = `${stamp}-${Math.random().toString(36).slice(2, 6)}`
      const runDir = path.join(FARM_ROOT, runId)
      fs.mkdirSync(runDir, { recursive: true })

      const logFile = path.join(runDir, 'farm.log')
      let logFd
      try {
        logFd = fs.openSync(logFile, 'a')
        const child = spawn(POWERSHELL, [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-File', SCRIPT,
          '-Action', 'farm',
          '-Runs', String(runs),
          '-Kind', kind,
          '-RunId', runId,
          '-RunDir', runDir,
          '-WindowTitle', cfg.windowTitle,
          '-ProcessName', cfg.processName,
        ], { detached: false, stdio: ['ignore', logFd, logFd], windowsHide: true })
        farmChildren.add(child)
        child.on('error', (error) => {
          farmChildren.delete(child)
          try {
            fs.appendFileSync(logFile, `\n[spawn-error] ${(error && error.message) || error}\n`)
          } catch { /* ignore */ }
          try { fs.closeSync(logFd) } catch { /* ignore */ }
        })
        child.on('exit', (code, signal) => {
          farmChildren.delete(child)
          try {
            fs.appendFileSync(logFile, `\n[exit] code=${code} signal=${signal}\n`)
          } catch { /* ignore */ }
          try { fs.closeSync(logFd) } catch { /* ignore */ }
        })
      } catch (error) {
        try { fs.closeSync(logFd) } catch { /* ignore */ }
        throw new Error(`启动托管失败：${(error && error.message) || error}`)
      }

      return {
        ok: true,
        runId,
        runs,
        kind,
        costPerRun,
        cost: totalCost,
        state: 'starting',
        path: path.join(runDir, 'status.json'),
        text: `${notice}已启动托管：${kindLabel}采光，连续 ${runs} 次，单场 ${costPerRun} 模块，预计消耗 ${totalCost} 个模块。\n`
          + `runId=${runId}\n用 limbus_farm_status 查看进度（可传 waitSeconds 等待）。`,
      }
    },
  })

  tools.register({
    name: 'limbus_farm_status',
    description:
      '查看半自动托管的进度与报告。不传 runId 看最近一次；waitSeconds 可在工具内轮询等待'
      + '（0~120 秒），减少模型往返。状态：starting/running/done/failed/partial。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        runId: { type: 'string' },
        waitSeconds: { type: 'number', minimum: 0, maximum: 120 },
      },
    },
    output: OUTPUT,
    async execute(args, exec) {
      const runId = String((args && args.runId) || '').trim() || latestFarmRun()
      if (!runId) return { ok: false, text: '还没有任何托管记录。先用 limbus_farm_start 启动。' }

      const runDir = path.join(FARM_ROOT, runId)
      const statusFile = path.join(runDir, 'status.json')
      const waitSeconds = Math.max(0, Math.min(120, Math.round(Number(args && args.waitSeconds) || 0)))
      const deadline = Date.now() + waitSeconds * 1000

      let status = readJsonFile(statusFile)
      while (
        (!status || status.state === 'starting' || status.state === 'running')
        && Date.now() < deadline
      ) {
        await new Promise((resolve) => setTimeout(resolve, 3000))
        if (exec && exec.signal && exec.signal.aborted) throw new Error('已取消')
        status = readJsonFile(statusFile)
      }

      const report = readJsonFile(path.join(runDir, 'report.json'))
      if (!status && !report) {
        return { ok: false, runId, text: `没有找到 ${runId} 的状态文件：${statusFile}` }
      }

      const state = (status && status.state) || (report && report.status) || 'unknown'
      const done = Number((status && status.done) ?? (report && report.done) ?? 0)
      const runs = Number((status && status.runs) ?? (report && report.runs) ?? 0)
      const kind = String((status && status.kind) || (report && report.kind) || '')
      const costPerRun = Number((status && status.costPerRun) ?? (report && report.costPerRun) ?? 0)
      const cost = Number((report && report.cost) ?? (done * costPerRun) ?? 0)
      const notes = String((status && status.error) || (report && report.notes) || '')
      const lines = [
        `runId ${runId}：${state}（${done}/${runs} 波）`,
        status && status.step ? `步骤：${status.step}` : '',
        notes ? `备注：${notes}` : '',
        costPerRun > 0 ? `模块：已消耗约 ${cost}（单场 ${costPerRun}）` : '',
        report ? `报告：${report.status}；回合 ${Array.isArray(report.turns) ? report.turns.join('/') : report.turns}` : '',
      ].filter(Boolean)

      return {
        ok: true,
        runId,
        state,
        done,
        runs,
        ...(kind ? { kind } : {}),
        ...(costPerRun > 0 ? { costPerRun, cost } : {}),
        notes,
        statusPath: statusFile,
        ...(report ? { report } : {}),
        text: lines.join('\n'),
      }
    },
  })

  tools.register({
    name: 'limbus_farm_stop',
    description: '停止半自动托管：写 stop 标记，并杀掉后台 farm 进程，防止它继续按 P/Enter。不会硬杀游戏。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: { runId: { type: 'string' } },
    },
    output: OUTPUT,
    async execute(args) {
      const runId = String((args && args.runId) || '').trim() || latestFarmRun()
      try { fs.writeFileSync(FARM_GLOBAL_STOP, 'stop\n', 'utf8') } catch { /* ignore */ }
      if (!runId) {
        await killFarmProcesses()
        return { ok: true, runId: '', text: '已清理所有后台 farm 进程。' }
      }
      const runDir = path.join(FARM_ROOT, runId)
      if (fs.existsSync(runDir)) {
        fs.writeFileSync(path.join(runDir, 'stop'), 'stop\n', 'utf8')
      }
      await killFarmProcesses()
      return {
        ok: true,
        runId,
        text: `已停止 ${runId} 并清理后台 farm 进程。`,
      }
    },
  })
}

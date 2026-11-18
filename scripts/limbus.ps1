# dsh-limbus — Windows 原语后端
#
# 由 index.js 以 `powershell.exe -File limbus.ps1 -Action <...>` 调用。
# 只做四件事：找窗口、截图、点击、按键。所有结果以一行
# `@@RESULT@@{json}` 输出，方便 Node 侧稳定解析。
#
# 为什么用 PowerShell：Windows 自带、不需要 npm 原生依赖；把 user32/gdi32
# 的 P/Invoke 编译成一个小 DLL 缓存在 %LOCALAPPDATA%，后续调用直接加载。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('info', 'windows', 'shot', 'click', 'key', 'focus', 'wait', 'farm')]
    [string]$Action,

    [string]$WindowTitle = 'Limbus',
    [string]$ProcessName = 'LimbusCompany',
    [string]$Out = '',
    [double]$RX = -1,
    [double]$RY = -1,
    [string]$Button = 'left',
    [switch]$Double,
    [string]$Key = '',
    [int]$WaitMs = 0,
    [int]$Runs = 1,
    [ValidateSet('exp', 'spindle')]
    [string]$Kind = 'exp',
    [string]$RunId = '',
    [string]$RunDir = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Marker = '@@RESULT@@'

function Send-Result($obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 8
    Write-Output ($Marker + $json)
}
function Write-FarmStatus([string]$dir, [string]$runId, [int]$runs, [string]$state, [int]$doneCount, [string]$step, [string]$errText, [string]$startedAt) {
    $obj = [ordered]@{
        runId = $runId; state = $state; runs = $runs; done = $doneCount
        kind = $Kind; costPerRun = $(if ($Kind -eq 'spindle') { 2 } else { 3 })
        step = $step; error = $errText; startedAt = $startedAt
        updatedAt = (Get-Date).ToString('o')
    }
    $json = $obj | ConvertTo-Json -Compress
    $tmp = Join-Path $dir 'status.json.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $tmp (Join-Path $dir 'status.json')
}

function Write-FarmReport([string]$dir, [string]$runId, [int]$runs, [int]$doneCount, [string]$state, [string]$startedAt, [string]$note, $turns) {
    $obj = [ordered]@{
        schemaVersion = 1; runId = $runId; game = 'limbus'; kind = $Kind
        stage = $(if ($Kind -eq 'spindle') { 60 } else { 10 })
        runs = $runs; done = $doneCount; status = $state
        costPerRun = $(if ($Kind -eq 'spindle') { 2 } else { 3 })
        cost = $doneCount * $(if ($Kind -eq 'spindle') { 2 } else { 3 })
        startedAt = $startedAt; endedAt = (Get-Date).ToString('o')
        notes = $note; turns = $turns
    }
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $tmp = Join-Path $dir 'report.json.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $tmp (Join-Path $dir 'report.json')
}

function Test-BattleEnded($h) {
    if ([LimbusWin]::IsVictoryStable($h)) { return 'victory' }
    if ([LimbusWin]::IsResultStable($h)) {
        # 可能是 VICTORY 动画/结算页；给结算标题最多 12 秒的宽限
        for ($g = 0; $g -lt 6; $g++) {
            Start-Sleep -Milliseconds 2000
            if ([LimbusWin]::IsVictoryStable($h)) { return 'victory' }
        }
        return 'not-victory'
    }
    return 'none'
}

function Test-VictorySplash($h) {
    return [LimbusWin]::IsVictorySplash($h)
}

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class LimbusWindowInfo
{
    public long Hwnd;
    public string Title = "";
    public string ClassName = "";
    public int Pid;
    public string ProcessName = "";
    public int Width;
    public int Height;
    public int ScreenX;
    public int ScreenY;
    public bool Foreground;
    public bool Minimized;
}

public static class LimbusWin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    private const int SW_RESTORE = 9;

    public static void MakeDpiAware()
    {
        try { SetProcessDPIAware(); } catch { }
    }

    public static string TitleOf(IntPtr h)
    {
        int len = GetWindowTextLength(h);
        if (len <= 0) return "";
        StringBuilder sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassNameOf(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ProcessNameOf(IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        if (pid == 0) return "";
        try { return Process.GetProcessById((int)pid).ProcessName; }
        catch { return ""; }
    }

    public static List<IntPtr> ListWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            if (GetWindowTextLength(h) <= 0) return true;
            list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static IntPtr Find(string titleSub, string processSub)
    {
        IntPtr best = IntPtr.Zero;
        long bestArea = -1;
        foreach (IntPtr h in ListWindows())
        {
            bool match = false;
            if (!string.IsNullOrEmpty(titleSub))
            {
                string title = TitleOf(h);
                if (title.IndexOf(titleSub, StringComparison.OrdinalIgnoreCase) >= 0) match = true;
            }
            if (!match && !string.IsNullOrEmpty(processSub))
            {
                string proc = ProcessNameOf(h);
                if (proc.IndexOf(processSub, StringComparison.OrdinalIgnoreCase) >= 0) match = true;
            }
            if (!match) continue;

            RECT r;
            if (!GetClientRect(h, out r)) continue;
            long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
            if (area > bestArea)
            {
                bestArea = area;
                best = h;
            }
        }
        return best;
    }

    public static LimbusWindowInfo Describe(IntPtr h)
    {
        LimbusWindowInfo info = new LimbusWindowInfo();
        info.Hwnd = h.ToInt64();
        info.Title = TitleOf(h);
        info.ClassName = ClassNameOf(h);
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        info.Pid = (int)pid;
        info.ProcessName = ProcessNameOf(h);

        RECT r;
        if (GetClientRect(h, out r))
        {
            info.Width = r.Right - r.Left;
            info.Height = r.Bottom - r.Top;
        }
        POINT p;
        p.X = 0;
        p.Y = 0;
        if (ClientToScreen(h, ref p))
        {
            info.ScreenX = p.X;
            info.ScreenY = p.Y;
        }
        info.Foreground = (GetForegroundWindow() == h);
        info.Minimized = IsIconic(h);
        return info;
    }

    public static bool Focus(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
        if (GetForegroundWindow() == h) return true;

        SetForegroundWindow(h);
        Thread.Sleep(120);
        if (GetForegroundWindow() == h) return true;

        IntPtr fg = GetForegroundWindow();
        uint pid;
        uint fgThread = GetWindowThreadProcessId(fg, out pid);
        uint curThread = GetCurrentThreadId();
        if (fgThread != 0 && fgThread != curThread)
        {
            AttachThreadInput(curThread, fgThread, true);
            BringWindowToTop(h);
            SetForegroundWindow(h);
            AttachThreadInput(curThread, fgThread, false);
        }
        else
        {
            BringWindowToTop(h);
            SetForegroundWindow(h);
        }
        Thread.Sleep(150);
        return GetForegroundWindow() == h;
    }

    public static bool Capture(IntPtr h, string path)
    {
        if (h == IntPtr.Zero) return false;
        Focus(h);

        RECT r;
        if (!GetClientRect(h, out r)) return false;
        int w = r.Right - r.Left;
        int ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return false;

        POINT p;
        p.X = 0;
        p.Y = 0;
        if (!ClientToScreen(h, ref p)) return false;

        try
        {
            using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format24bppRgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.CopyFromScreen(p.X, p.Y, 0, 0, new Size(w, ht), CopyPixelOperation.SourceCopy);
                }
                bmp.Save(path, ImageFormat.Png);
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static bool Click(IntPtr h, double rx, double ry, bool right, bool dbl)
    {
        if (h == IntPtr.Zero) return false;
        if (!Focus(h)) return false;

        RECT r;
        if (!GetClientRect(h, out r)) return false;
        int w = r.Right - r.Left;
        int ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return false;

        double cx = Math.Max(0.0, Math.Min(1.0, rx));
        double cy = Math.Max(0.0, Math.Min(1.0, ry));
        int x = (int)Math.Round(cx * (w - 1));
        int y = (int)Math.Round(cy * (ht - 1));

        POINT p;
        p.X = x;
        p.Y = y;
        if (!ClientToScreen(h, ref p)) return false;

        SetCursorPos(p.X, p.Y);
        Thread.Sleep(70);

        uint down = right ? 0x0008u : 0x0002u;
        uint up = right ? 0x0010u : 0x0004u;
        mouse_event(down, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(45);
        mouse_event(up, 0, 0, 0, UIntPtr.Zero);
        if (dbl)
        {
            Thread.Sleep(90);
            mouse_event(down, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(45);
            mouse_event(up, 0, 0, 0, UIntPtr.Zero);
        }
        return true;
    }

    private class RegionStat
    {
        public int Total;
        public int Warm;
        public int Yellow;
        public int Cyan;
        public int Bright;
    }

    private static RegionStat Analyze(IntPtr h, double rx, double ry, double rw, double rh)
    {
        RegionStat stat = new RegionStat();
        RECT r;
        if (!GetClientRect(h, out r)) return stat;
        int cw = r.Right - r.Left;
        int ch = r.Bottom - r.Top;
        if (cw <= 0 || ch <= 0) return stat;

        int x = (int)Math.Round(rx * cw);
        int y = (int)Math.Round(ry * ch);
        int w = (int)Math.Round(rw * cw);
        int hh = (int)Math.Round(rh * ch);
        if (w <= 0 || hh <= 0) return stat;

        POINT p;
        p.X = x;
        p.Y = y;
        if (!ClientToScreen(h, ref p)) return stat;

        try
        {
            using (Bitmap bmp = new Bitmap(w, hh, PixelFormat.Format24bppRgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.CopyFromScreen(p.X, p.Y, 0, 0, new Size(w, hh), CopyPixelOperation.SourceCopy);
                }
                BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, hh), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try
                {
                    int stride = bd.Stride;
                    byte[] data = new byte[stride * hh];
                    Marshal.Copy(bd.Scan0, data, 0, data.Length);
                    for (int yy = 0; yy < hh; yy++)
                    {
                        int row = yy * stride;
                        for (int xx = 0; xx < w; xx++)
                        {
                            int i = row + xx * 3;
                            int b = data[i];
                            int g2 = data[i + 1];
                            int r2 = data[i + 2];
                            stat.Total++;
                            if (r2 > 180 && g2 > 150 && b > 100) stat.Warm++;
                            if (r2 > 180 && g2 > 140 && b < 100) stat.Yellow++;
                            if (b > 140 && g2 > 110 && r2 < 120) stat.Cyan++;
                            if (r2 > 150 && g2 > 150 && b > 150) stat.Bright++;
                        }
                    }
                }
                finally
                {
                    bmp.UnlockBits(bd);
                }
            }
        }
        catch
        {
        }
        return stat;
    }

    /** 结算页「确认」按钮区域是否以暖白为主（战斗界面该区域是暗色/红色）。 */
    public static bool IsResult(IntPtr h)
    {
        RegionStat s = Analyze(h, 0.815, 0.745, 0.130, 0.097);
        return s.Total > 0 && (double)s.Warm / s.Total > 0.03;
    }

    /** 结算页右上「战斗胜利」黄字比例；失败/普通战斗界面明显更低。 */
    public static bool IsVictory(IntPtr h)
    {
        RegionStat s = Analyze(h, 0.792, 0.157, 0.156, 0.093);
        return s.Total > 0 && (double)s.Yellow / s.Total > 0.05;
    }

    /** 连续两次都看到「战斗胜利」黄字才算真结算；避免动画单帧误判。 */
    public static bool IsVictoryStable(IntPtr h)
    {
        if (!IsVictory(h)) return false;
        Thread.Sleep(700);
        return IsVictory(h);
    }

    /** 居中的巨大 VICTORY 动画（结算页之前）：必须已离开战斗 HUD，且连续两帧都在。 */
    public static bool IsVictorySplash(IntPtr h)
    {
        if (IsBattleHud(h)) return false;
        RegionStat s = Analyze(h, 0.39, 0.38, 0.23, 0.17);
        if (!(s.Total > 0 && (double)s.Yellow / s.Total > 0.10)) return false;
        Thread.Sleep(700);
        if (IsBattleHud(h)) return false;
        s = Analyze(h, 0.39, 0.38, 0.23, 0.17);
        return s.Total > 0 && (double)s.Yellow / s.Total > 0.10;
    }

    /** 高阈值 + 连续两次：只用于“已经到结算页”的判定，避免战斗动画误报。 */
    public static bool IsResultStable(IntPtr h)
    {
        RegionStat s = Analyze(h, 0.815, 0.745, 0.130, 0.097);
        if (!(s.Total > 0 && (double)s.Warm / s.Total > 0.08)) return false;
        Thread.Sleep(700);
        s = Analyze(h, 0.815, 0.745, 0.130, 0.097);
        return s.Total > 0 && (double)s.Warm / s.Total > 0.08;
    }

    /** 队伍页「开始战斗」是否已点亮（有队伍时是青色；0/12 时是暗色）。 */
    public static bool IsStartEnabled(IntPtr h)
    {
        RegionStat s = Analyze(h, 0.800, 0.790, 0.160, 0.100);
        return s.Total > 0 && (double)s.Cyan / s.Total > 0.005;
    }

    /** 战斗 HUD 右上角暂停/设置图标；离开战斗回到采光后该区域是暗的。 */
    public static bool IsBattleHud(IntPtr h)
    {
        RegionStat s = Analyze(h, 0.900, 0.020, 0.080, 0.060);
        return s.Total > 0 && (double)s.Bright / s.Total > 0.01;
    }

    public static bool PressKey(string name)
    {
        int vk = Vk(name);
        if (vk <= 0) return false;
        keybd_event((byte)vk, 0, 0, UIntPtr.Zero);
        Thread.Sleep(45);
        keybd_event((byte)vk, 0, 2, UIntPtr.Zero);
        return true;
    }

    private static int Vk(string name)
    {
        if (string.IsNullOrEmpty(name)) return 0;
        string n = name.Trim().ToLowerInvariant();
        if (n.Length == 1)
        {
            char c = n[0];
            if (c >= 'a' && c <= 'z') return (int)char.ToUpperInvariant(c);
            if (c >= '0' && c <= '9') return (int)c;
        }
        switch (n)
        {
            case "enter":
            case "return": return 0x0D;
            case "esc":
            case "escape": return 0x1B;
            case "space": return 0x20;
            case "tab": return 0x09;
            case "backspace": return 0x08;
            case "up": return 0x26;
            case "down": return 0x28;
            case "left": return 0x25;
            case "right": return 0x27;
        }
        if (n.Length >= 2 && n[0] == 'f')
        {
            int num;
            if (int.TryParse(n.Substring(1), out num) && num >= 1 && num <= 12)
                return 0x70 + num - 1;
        }
        return 0;
    }
}
'@

try {
    $cacheDir = Join-Path $env:LOCALAPPDATA 'dsh-limbus-control'
    $dll = Join-Path $cacheDir 'LimbusWin-v8.dll'
    if (-not (Test-Path $dll)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Drawing' -OutputAssembly $dll
    }
    if (-not ('LimbusWin' -as [type])) {
        Add-Type -Path $dll
    }
    [LimbusWin]::MakeDpiAware()

    switch ($Action) {
        'info' {
            $h = [LimbusWin]::Find($WindowTitle, $ProcessName)
            if ($h -eq [IntPtr]::Zero) {
                $wins = @()
                foreach ($w in [LimbusWin]::ListWindows()) { $wins += [LimbusWin]::TitleOf($w) }
                Send-Result @{ ok = $false; error = 'window-not-found'; windows = @($wins) }
                exit 0
            }
            $info = [LimbusWin]::Describe($h)
            Send-Result @{
                ok = $true
                window = @{
                    hwnd = $info.Hwnd; title = $info.Title; process = $info.ProcessName
                    pid = $info.Pid; width = $info.Width; height = $info.Height
                    screenX = $info.ScreenX; screenY = $info.ScreenY
                    foreground = $info.Foreground; minimized = $info.Minimized
                }
            }
            exit 0
        }

        'windows' {
            $wins = @()
            foreach ($w in [LimbusWin]::ListWindows()) {
                $wins += [LimbusWin]::TitleOf($w)
            }
            Send-Result @{ ok = $true; windows = @($wins) }
            exit 0
        }

        'shot' {
            $h = [LimbusWin]::Find($WindowTitle, $ProcessName)
            if ($h -eq [IntPtr]::Zero) {
                Send-Result @{ ok = $false; error = 'window-not-found' }
                exit 0
            }
            if ([string]::IsNullOrWhiteSpace($Out)) {
                $dir = Join-Path $env:TEMP 'dsh-limbus-control\shots'
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $Out = Join-Path $dir ('limbus-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.png')
            }
            $dirOut = Split-Path -Parent $Out
            if ($dirOut) { New-Item -ItemType Directory -Force -Path $dirOut | Out-Null }
            $ok = [LimbusWin]::Capture($h, $Out)
            if (-not $ok) {
                Send-Result @{ ok = $false; error = 'capture-failed' }
                exit 0
            }
            $info = [LimbusWin]::Describe($h)
            Send-Result @{
                ok = $true; path = $Out; width = $info.Width; height = $info.Height
                foreground = $info.Foreground
                window = @{
                    hwnd = $info.Hwnd; title = $info.Title; process = $info.ProcessName
                    pid = $info.Pid; width = $info.Width; height = $info.Height
                    screenX = $info.ScreenX; screenY = $info.ScreenY
                    foreground = $info.Foreground; minimized = $info.Minimized
                }
            }
            exit 0
        }

        'click' {
            if ($RX -lt 0 -or $RX -gt 1 -or $RY -lt 0 -or $RY -gt 1) {
                Send-Result @{ ok = $false; error = 'bad-coordinates' }
                exit 0
            }
            $h = [LimbusWin]::Find($WindowTitle, $ProcessName)
            if ($h -eq [IntPtr]::Zero) {
                Send-Result @{ ok = $false; error = 'window-not-found' }
                exit 0
            }
            # 先恢复/置前，再按恢复后的客户区尺寸换算坐标；
            # 否则最小化的窗口会算出 0x0 的坐标。
            [void][LimbusWin]::Focus($h)
            $before = [LimbusWin]::Describe($h)
            $x = [int][Math]::Round($RX * ($before.Width - 1))
            $y = [int][Math]::Round($RY * ($before.Height - 1))
            $ok = [LimbusWin]::Click($h, $RX, $RY, ($Button -eq 'right'), [bool]$Double)
            $after = [LimbusWin]::Describe($h)
            Send-Result @{
                ok = $ok; x = $x; y = $y; width = $before.Width; height = $before.Height
                foreground = $after.Foreground
            }
            exit 0
        }

        'key' {
            $h = [LimbusWin]::Find($WindowTitle, $ProcessName)
            if ($h -eq [IntPtr]::Zero) {
                Send-Result @{ ok = $false; error = 'window-not-found' }
                exit 0
            }
            [void][LimbusWin]::Focus($h)
            $ok = [LimbusWin]::PressKey($Key)
            Send-Result @{ ok = $ok }
            exit 0
        }

        'focus' {
            $h = [LimbusWin]::Find($WindowTitle, $ProcessName)
            if ($h -eq [IntPtr]::Zero) {
                Send-Result @{ ok = $false; error = 'window-not-found' }
                exit 0
            }
            $ok = [LimbusWin]::Focus($h)
            $info = [LimbusWin]::Describe($h)
            Send-Result @{
                ok = $ok
                window = @{
                    hwnd = $info.Hwnd; title = $info.Title; process = $info.ProcessName
                    pid = $info.Pid; width = $info.Width; height = $info.Height
                    screenX = $info.ScreenX; screenY = $info.ScreenY
                    foreground = $info.Foreground; minimized = $info.Minimized
                }
            }
            exit 0
        }

        'farm' {
            if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') }
            if ([string]::IsNullOrWhiteSpace($RunDir)) { $RunDir = Join-Path (Join-Path $env:LOCALAPPDATA 'dsh-limbus-control\farm') $RunId }
            New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
            $stopFile = Join-Path $RunDir 'stop'
            $globalStop = Join-Path (Join-Path $env:LOCALAPPDATA 'dsh-limbus-control') 'farm.stop'
            $startedAt = (Get-Date).ToString('o')
            $hardDeadline = (Get-Date).AddMinutes(5 + 3 * $Runs)
            $done = 0
            $finalState = 'failed'
            $notes = ''
            $turnsUsed = @()

            Write-FarmStatus $RunDir $RunId $Runs 'starting' 0 'preflight' '' $startedAt
            $h = [LimbusWin]::Find($WindowTitle, $ProcessName)
            if ($h -eq [IntPtr]::Zero) {
                $notes = 'window-not-found'
            } else {
                $info = [LimbusWin]::Describe($h)
                if ($info.Width -le 0 -or $info.Height -le 0) {
                    $notes = 'bad-window-size'
                } else {
                    $ratio = $info.Width / $info.Height
                    if ([Math]::Abs($ratio - (16.0 / 9.0)) -gt 0.03) { $notes = 'not-16-9' }
                }
            }

            if ($notes -ne '') {
                Write-FarmStatus $RunDir $RunId $Runs 'failed' 0 'preflight' $notes $startedAt
                Write-FarmReport $RunDir $RunId $Runs 0 'failed' $startedAt $notes $turnsUsed
                Send-Result @{ ok = $false; error = $notes; runId = $RunId; path = $RunDir }
                exit 0
            }

            if ($Runs -le 0) {
                Write-FarmStatus $RunDir $RunId $Runs 'done' 0 'preflight' '' $startedAt
                Write-FarmReport $RunDir $RunId $Runs 0 'success' $startedAt 'preflight-only' $turnsUsed
                Send-Result @{ ok = $true; runId = $RunId; preflightOnly = $true; width = $info.Width; height = $info.Height; path = $RunDir }
                exit 0
            }

            Write-FarmStatus $RunDir $RunId $Runs 'running' 0 'navigate' '' $startedAt
            [void][LimbusWin]::Click($h, 0.764, 0.92, $false, $false)
            Start-Sleep -Milliseconds 1200
            [void][LimbusWin]::Click($h, 0.34, 0.26, $false, $false)
            Start-Sleep -Milliseconds 1400

            # 经验 / 纺锤（灯泡）页签
            if ($Kind -eq 'spindle') {
                [void][LimbusWin]::Click($h, 0.133, 0.444, $false, $false)
            } else {
                [void][LimbusWin]::Click($h, 0.133, 0.361, $false, $false)
            }
            Start-Sleep -Milliseconds 900

            if ($Kind -eq 'spindle') {
                # 纺锤：最左每日副本 -> 选关弹窗
                [void][LimbusWin]::Click($h, 0.318, 0.66, $false, $false)
                Start-Sleep -Milliseconds 1100
                # 弹窗里的「连续进行」：开步进器 -> 归 1 -> 加到 n
                [void][LimbusWin]::Click($h, 0.59, 0.245, $false, $false)
                Start-Sleep -Milliseconds 400
                [void][LimbusWin]::Click($h, 0.422, 0.299, $false, $false)
                Start-Sleep -Milliseconds 250
                for ($step = 1; $step -lt $Runs; $step++) {
                    [void][LimbusWin]::Click($h, 0.5625, 0.299, $false, $false)
                    Start-Sleep -Milliseconds 300
                }
                # 最下面 Lv60「精灵提灯」：资源最多，点它的「进入」按钮（y≈0.62）
                [void][LimbusWin]::Click($h, 0.64, 0.62, $false, $false)
                Start-Sleep -Milliseconds 1800
            } else {
                if ($Runs -gt 1) {
                    [void][LimbusWin]::Click($h, 0.82, 0.45, $false, $false)
                    Start-Sleep -Milliseconds 500
                    for ($step = 1; $step -lt $Runs; $step++) {
                        [void][LimbusWin]::Click($h, 0.921, 0.389, $false, $false)
                        Start-Sleep -Milliseconds 300
                    }
                }
                [void][LimbusWin]::Click($h, 0.87, 0.66, $false, $false)
                Start-Sleep -Milliseconds 1800
            }
            Start-Sleep -Milliseconds 1200
            if (-not [LimbusWin]::IsStartEnabled($h)) {
                $notes = 'team-empty'
                Write-FarmStatus $RunDir $RunId $Runs 'failed' 0 'team' $notes $startedAt
                Write-FarmReport $RunDir $RunId $Runs 0 'failed' $startedAt $notes $turnsUsed
                Send-Result @{ ok = $false; error = $notes; runId = $RunId; path = $RunDir }
                exit 0
            }
            [void][LimbusWin]::Click($h, 0.88, 0.83, $false, $false)
            Start-Sleep -Milliseconds 3000

            $totalTurns = 0
            $won = $false
            $noHud = 0
            $battleSeen = $false
            $maxTurns = (10 * $Runs) + 10
            for ($turn = 1; $turn -le $maxTurns; $turn++) {
                if ((Test-Path $stopFile) -or (Test-Path $globalStop)) { $notes = 'stopped-by-user'; break }
                if ((Get-Date) -gt $hardDeadline) { $notes = 'hard-timeout'; break }
                if (-not $battleSeen) {
                    if ([LimbusWin]::IsBattleHud($h)) {
                        $battleSeen = $true
                        $noHud = 0
                    } else {
                        $noHud++
                        if ($noHud -ge 8) { $notes = 'left-battle'; break }
                        Start-Sleep -Milliseconds 1000
                        continue
                    }
                }
                if (Test-VictorySplash $h) { $won = $true; break }
                if ([LimbusWin]::IsVictoryStable($h)) { $won = $true; break }
                if ([LimbusWin]::IsResultStable($h)) { $notes = 'battle-not-victory'; break }
                if (-not [LimbusWin]::IsBattleHud($h)) {
                    $noHud++
                    if ($noHud -ge 8) { $notes = 'left-battle'; break }
                    Start-Sleep -Milliseconds 1000
                    continue
                }
                $noHud = 0
                $totalTurns = $turn
                [void][LimbusWin]::PressKey('p')
                Start-Sleep -Milliseconds 700
                [void][LimbusWin]::PressKey('enter')
                for ($poll = 0; $poll -lt 8; $poll++) {
                    Start-Sleep -Milliseconds 2000
                    if ((Test-Path $stopFile) -or (Test-Path $globalStop)) { $notes = 'stopped-by-user'; break }
                    if ((Get-Date) -gt $hardDeadline) { $notes = 'hard-timeout'; break }
                    if (-not $battleSeen) {
                        if ([LimbusWin]::IsBattleHud($h)) {
                            $battleSeen = $true
                            $noHud = 0
                        } else {
                            $noHud++
                            if ($noHud -ge 8) { $notes = 'left-battle'; break }
                            continue
                        }
                    }
                    if (Test-VictorySplash $h) { $won = $true; break }
                    if ([LimbusWin]::IsVictoryStable($h)) { $won = $true; break }
                    if ([LimbusWin]::IsResultStable($h)) { $notes = 'battle-not-victory'; break }
                    if (-not [LimbusWin]::IsBattleHud($h)) {
                        $noHud++
                        if ($noHud -ge 8) { $notes = 'left-battle'; break }
                    } else {
                        $noHud = 0
                    }
                }
                if ($notes -eq 'stopped-by-user') { break }
                if ($notes -eq 'battle-not-victory') { break }
                if ($won) { break }
            }

            if ($notes -eq '') {
                if (-not $won) {
                    $notes = 'battle-timeout'
                } else {
                    $finalVictory = $false
                    for ($wait = 0; $wait -lt 6; $wait++) {
                        if ([LimbusWin]::IsVictoryStable($h)) { $finalVictory = $true; break }
                        [void][LimbusWin]::PressKey('enter')
                        Start-Sleep -Milliseconds 2000
                    }
                    if (-not $finalVictory) {
                        $notes = 'splash-stuck'
                    } else {
                        for ($k = 0; $k -lt 3; $k++) {
                            [void][LimbusWin]::Click($h, 0.88, 0.82, $false, $false)
                            Start-Sleep -Milliseconds 2200
                            if (-not [LimbusWin]::IsVictory($h)) { break }
                        }
                        if ([LimbusWin]::IsVictory($h)) { $notes = 'result-stuck' }
                    }
                }
            }

            if ($notes -eq '') {
                $done = $Runs
                $turnsUsed = @($totalTurns)
                $finalState = 'success'
                $notes = 'completed'
            } elseif ($notes -eq 'stopped-by-user') {
                $done = 0
                $finalState = 'partial'
            } else {
                $done = 0
                $finalState = 'failed'
            }
            Write-FarmStatus $RunDir $RunId $Runs $finalState $done 'done' $notes $startedAt
            Write-FarmReport $RunDir $RunId $Runs $done $finalState $startedAt $notes $turnsUsed
            Send-Result @{ ok = ($finalState -eq 'success'); runId = $RunId; state = $finalState; done = $done; runs = $Runs; path = $RunDir; notes = $notes }
            exit 0
        }

        'wait' {
            if ($WaitMs -lt 0) { $WaitMs = 0 }
            if ($WaitMs -gt 30000) { $WaitMs = 30000 }
            Start-Sleep -Milliseconds $WaitMs
            Send-Result @{ ok = $true; waited = $WaitMs }
            exit 0
        }
    }
}
catch {
    Send-Result @{ ok = $false; error = $_.Exception.Message }
    exit 0
}

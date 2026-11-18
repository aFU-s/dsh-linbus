param(
    [string]$Data = (Join-Path $PSScriptRoot 'token-context.json'),
    [string]$Out = (Join-Path $PSScriptRoot 'token-consumption.png')
)

Add-Type -AssemblyName System.Drawing

$d = Get-Content $Data -Raw | ConvertFrom-Json
$b = $d.breakdown
$total = [double]$d.total
$fixed = [double]$b.system + [double]$b.schema + [double]$b.user
$items = @(
    @{ label = '工具结果文本'; value = [double]$b.tool; color = [System.Drawing.Color]::FromArgb(245, 158, 11) },
    @{ label = '助手历史（推理+工具参数）'; value = [double]$b.assistant; color = [System.Drawing.Color]::FromArgb(56, 189, 248) },
    @{ label = '截图 / 图片'; value = [double]$b.images; color = [System.Drawing.Color]::FromArgb(167, 139, 250) },
    @{ label = '系统提示 + 工具 schema'; value = $fixed; color = [System.Drawing.Color]::FromArgb(100, 116, 139) }
)

$W = 1600
$H = 1000
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$bg = [System.Drawing.Color]::FromArgb(11, 18, 32)
$g.Clear($bg)

$text = [System.Drawing.Color]::FromArgb(229, 231, 235)
$muted = [System.Drawing.Color]::FromArgb(148, 163, 184)
$panel = [System.Drawing.Color]::FromArgb(17, 24, 39)

$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei', 26, [System.Drawing.FontStyle]::Bold)
$fontSub = New-Object System.Drawing.Font('Microsoft YaHei', 12)
$fontLabel = New-Object System.Drawing.Font('Microsoft YaHei', 13)
$fontBig = New-Object System.Drawing.Font('Microsoft YaHei', 20, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei', 10)

$brushText = New-Object System.Drawing.SolidBrush($text)
$brushMuted = New-Object System.Drawing.SolidBrush($muted)
$brushPanel = New-Object System.Drawing.SolidBrush($panel)

$g.DrawString('DSH 边狱巴士流程 · Token 消耗分布', $fontTitle, $brushText, 60, 40)
$sub = "基于 {0:N0} 次模型往返、{1:N0} 次工具调用、{2:N0} 张图；累计输入 ~{3:N1}M token" -f $d.steps, $d.toolCalls, $d.images, ($total / 1e6)
$g.DrawString($sub, $fontSub, $brushMuted, 62, 88)

# ---- pie / donut ----
$cx = 350
$cy = 470
$r = 220
$start = -90.0
foreach ($it in $items) {
    $sweep = $it.value / $total * 360.0
    $brush = New-Object System.Drawing.SolidBrush($it.color)
    $g.FillPie($brush, $cx - $r, $cy - $r, 2 * $r, 2 * $r, [float]$start, [float]$sweep)
    $brush.Dispose()
    $start += $sweep
}
$hole = New-Object System.Drawing.SolidBrush($bg)
$g.FillEllipse($hole, $cx - 110, $cy - 110, 220, 220)
$hole.Dispose()

$centerFmt = New-Object System.Drawing.StringFormat
$centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
$centerFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$g.DrawString(("{0:N1}M" -f ($total / 1e6)), $fontBig, $brushText, $cx, $cy - 18, $centerFmt)
$g.DrawString('累计输入 token', $fontSmall, $brushMuted, $cx, $cy + 18, $centerFmt)

# ---- legend ----
$x = 650
$y = 170
foreach ($it in $items) {
    $brush = New-Object System.Drawing.SolidBrush($it.color)
    $g.FillRectangle($brush, $x, $y, 18, 18)
    $brush.Dispose()
    $pct = $it.value / $total * 100
    $g.DrawString($it.label, $fontLabel, $brushText, $x + 30, $y - 3)
    $val = "{0:N1}M  ({1:N1}%)" -f ($it.value / 1e6), $pct
    $g.DrawString($val, $fontSub, $brushMuted, $x + 30, $y + 22)
    $y += 72
}

$noteY = 470
$toolPct = [double]$b.tool / $total * 100
$asstPct = [double]$b.assistant / $total * 100
$imgPct = [double]$b.images / $total * 100
$histPct = $toolPct + $asstPct
$g.DrawString(("结论：{0:N0}% 花在每一步重发历史" -f $histPct), $fontBig, $brushText, 650, $noteY)
$g.DrawString(("工具结果 {0:N1}% + 助手历史 {1:N1}%；截图只占 {2:N1}%。" -f $toolPct, $asstPct, $imgPct), $fontSub, $brushMuted, 650, $noteY + 38)
$g.DrawString('减少模型往返、压缩历史，比少截几张图更省钱。', $fontSub, $brushMuted, 650, $noteY + 66)

# ---- line chart: context per step ----
$chartX = 90
$chartY = 740
$chartW = 1420
$chartH = 190
$g.FillRectangle($brushPanel, $chartX, $chartY, $chartW, $chartH)

$perStep = @($d.perStep | ForEach-Object { [double]$_ })
$maxVal = ($perStep | Measure-Object -Maximum).Maximum
$yMax = [Math]::Ceiling($maxVal / 200000.0) * 200000.0
if ($yMax -le 0) { $yMax = 1000000.0 }

$gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(45, 55, 72), 1)
for ($i = 0; $i -le 4; $i++) {
    $yy = $chartY + $chartH - ($chartH * $i / 4)
    $g.DrawLine($gridPen, $chartX, $yy, $chartX + $chartW, $yy)
    $label = ("{0:N0}" -f ($yMax * $i / 4))
    $g.DrawString($label, $fontSmall, $brushMuted, $chartX + 6, $yy + 2)
}
$gridPen.Dispose()

$n = $perStep.Count
$points = New-Object System.Drawing.PointF[] $n
for ($i = 0; $i -lt $n; $i++) {
    $px = $chartX + ($chartW * $i / [Math]::Max(1, $n - 1))
    $py = $chartY + $chartH - ($perStep[$i] / $yMax * $chartH)
    $points[$i] = New-Object System.Drawing.PointF([float]$px, [float]$py)
}

$fillPts = New-Object System.Drawing.PointF[] ($n + 2)
for ($i = 0; $i -lt $n; $i++) { $fillPts[$i] = $points[$i] }
$fillPts[$n] = New-Object System.Drawing.PointF([float]($chartX + $chartW), [float]($chartY + $chartH))
$fillPts[$n + 1] = New-Object System.Drawing.PointF([float]$chartX, [float]($chartY + $chartH))
$fillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 56, 189, 248))
$g.FillPolygon($fillBrush, $fillPts)
$fillBrush.Dispose()

$linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(56, 189, 248), 2)
if ($n -ge 2) { $g.DrawLines($linePen, $points) }
$linePen.Dispose()

$g.DrawString('每步重发的上下文（token）', $fontLabel, $brushText, $chartX + 12, $chartY - 48)
$g.DrawString(("step 1 → {0}：{1:N0} → {2:N0} token/步" -f $n, $perStep[0], $perStep[$n - 1]), $fontSub, $brushMuted, $chartX + 12, $chartY - 24)
$g.DrawString('后期每步 40 万+', $fontSmall, $brushMuted, $chartX + $chartW - 190, $chartY - 44)

$fontTitle.Dispose(); $fontSub.Dispose(); $fontLabel.Dispose(); $fontBig.Dispose(); $fontSmall.Dispose()
$brushText.Dispose(); $brushMuted.Dispose(); $brushPanel.Dispose()
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "saved $Out"

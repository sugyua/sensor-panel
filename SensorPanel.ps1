# ═══════════════════════════════════════════════════════════════
#  SYSTEM MONITOR  —  AMD Ryzen 5 5600X  +  RX 7800 XT
#  Fontes: HWiNFO64 (memória compartilhada) + RTSS (FPS) + WMI
# ═══════════════════════════════════════════════════════════════

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Collections.Generic;

public class HWiNFOReading {
    public string Label;
    public string Unit;
    public double Value;
    public uint   SensorIndex;
    public uint   Type;
}

public class HWiNFOSensor {
    public string Name;
    public uint   SensorID;
}

public class HWiNFOReader {
    const string SM = "Global\\HWiNFO_SENS_SM2";

    public static bool IsRunning() {
        try { using (MemoryMappedFile.OpenExisting(SM)) {} return true; }
        catch { return false; }
    }

    public static List<HWiNFOReading> GetReadings(out List<HWiNFOSensor> sensors) {
        sensors = new List<HWiNFOSensor>();
        var list = new List<HWiNFOReading>();
        try {
            using (var mmf  = MemoryMappedFile.OpenExisting(SM))
            using (var view = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                if (view.ReadUInt32(0) != 0x53695748) return list;
                uint offS = view.ReadUInt32(20); uint szS = view.ReadUInt32(24); uint nS = view.ReadUInt32(28);
                uint offR = view.ReadUInt32(32); uint szR = view.ReadUInt32(36); uint nR = view.ReadUInt32(40);
                byte[] b128 = new byte[128]; byte[] b16 = new byte[16];
                for (uint i = 0; i < nS; i++) {
                    long b = offS + i * szS;
                    var s = new HWiNFOSensor();
                    s.SensorID = view.ReadUInt32(b);
                    view.ReadArray(b + 8, b128, 0, 128);
                    s.Name = Encoding.UTF8.GetString(b128).TrimEnd('\0');
                    sensors.Add(s);
                }
                for (uint i = 0; i < nR; i++) {
                    long b = offR + i * szR;
                    var r = new HWiNFOReading();
                    r.Type        = view.ReadUInt32(b);
                    r.SensorIndex = view.ReadUInt32(b + 4);
                    view.ReadArray(b + 12,  b128, 0, 128);
                    r.Label = Encoding.UTF8.GetString(b128).TrimEnd('\0');
                    view.ReadArray(b + 268, b16,  0, 16);
                    r.Unit  = Encoding.UTF8.GetString(b16).TrimEnd('\0');
                    r.Value = view.ReadDouble(b + 284);
                    list.Add(r);
                }
            }
        } catch {}
        return list;
    }
}

public class RTSSReader {
    const string SM = "Global\\RTSSSharedMemoryV2";

    public static int GetFPS() {
        try {
            using (var mmf  = MemoryMappedFile.OpenExisting(SM))
            using (var view = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                if (view.ReadUInt32(0) != 0x53535452) return -1;
                uint appEntrySize = view.ReadUInt32(8);
                uint appArrOffset = view.ReadUInt32(12);
                uint appArrSize   = view.ReadUInt32(16);
                if (appEntrySize == 0 || appArrSize == 0) return -1;

                int[,] offsetSets = new int[,] {
                    { 276, 268, 272 },
                    { 532, 524, 528 },
                    { 796, 800, 804 },
                    { 280, 284, 288 },
                };

                int bestFps = -1;
                for (uint i = 0; i < appArrSize; i++) {
                    long b   = appArrOffset + i * appEntrySize;
                    uint pid = view.ReadUInt32(b);
                    if (pid == 0) continue;

                    for (int s = 0; s < offsetSets.GetLength(0); s++) {
                        long oFrames = offsetSets[s, 0];
                        long oT0     = offsetSets[s, 1];
                        long oT1     = offsetSets[s, 2];
                        if (oFrames >= appEntrySize || oT1 >= appEntrySize) continue;

                        uint frames = view.ReadUInt32(b + oFrames);
                        uint time0  = view.ReadUInt32(b + oT0);
                        uint time1  = view.ReadUInt32(b + oT1);

                        if (frames > 0 && time1 > time0) {
                            double elapsed = (time1 - time0) / 1000.0;
                            if (elapsed > 0.01) {
                                int fps = (int)Math.Round(frames / elapsed);
                                if (fps > 0 && fps < 5000 && fps > bestFps)
                                    bestFps = fps;
                            }
                        }
                    }
                }
                return bestFps;
            }
        } catch { return -1; }
    }
}
"@

# ── Coleta de métricas ─────────────────────────────────────────
function Get-SystemStats {
    $s = @{
        CpuName    = "AMD Ryzen 5 5600X"
        CpuTemp    = $null; CpuLoad = $null; CpuClk = $null
        GpuName    = "AMD RX 7800 XT"
        GpuTemp    = $null; GpuLoad = $null; GpuClk = $null; GpuVram = $null
        RamPct     = $null; RamUsedMB = $null; RamTotalMB = $null
        Fps        = $null; Source = "WMI"
    }

    $fps = [RTSSReader]::GetFPS()
    if ($fps -ge 0) { $s.Fps = $fps }

    if ([HWiNFOReader]::IsRunning()) {
        $s.Source = "HWiNFO64"
        $sensors  = $null
        $readings = [HWiNFOReader]::GetReadings([ref]$sensors)

        $cpuIdx = -1; $gpuIdx = -1
        for ($i = 0; $i -lt $sensors.Count; $i++) {
            $n = $sensors[$i].Name.ToLower()
            if ($cpuIdx -eq -1 -and $n -match 'ryzen|5600|processor|cpu') {
                $cpuIdx = $i
                $cleanName = $sensors[$i].Name -replace '^(CPU|APU|MCM)\s*\[#\d+\]:\s*', ''
                $cleanName = $cleanName -replace '\s*\(.*?\)\s*$', ''
                $s.CpuName = $cleanName.Trim()
            }
            if ($gpuIdx -eq -1 -and ($n -match 'radeon|rx 7800|7800 xt|rx78' -or
                                      ($n -match 'gpu' -and $n -notmatch 'cpu'))) {
                $gpuIdx = $i
                $cleanName = $sensors[$i].Name -replace '^[a-zA-Z]*GPU\s*\[#\d+\]:\s*', ''
                $cleanName = ($cleanName -split '[;:]')[0]
                $cleanName = $cleanName -replace '\s*\(.*?\)\s*$', ''
                $s.GpuName = $cleanName.Trim()
            }
        }

        $cpuTempC = @(); $gpuTempC = @(); $gpuClkC = @(); $gpuVramC = @()

        foreach ($r in $readings) {
            $lbl = $r.Label.ToLower()
            $typ = [int]$r.Type
            $idx = [int]$r.SensorIndex
            $val = $r.Value

            # ══ CPU temperatura ══
            if ($typ -eq 1 -and $val -ge 10 -and $val -lt 115) {
                $sc = 0
                if    ($lbl -match 'tdie|tctl')                                                       { $sc = 100 }
                elseif($lbl -match 'cpu package|package temp')                                        { $sc = 90  }
                elseif($lbl -match 'cpu die|die avg')                                                 { $sc = 85  }
                elseif($lbl -match 'cpu.*temp' -and $lbl -notmatch '#\d|core\s*\d')                 { $sc = 80  }
                elseif($lbl -match 'cpu \(t|\(tdie|\(tctl|processor.*temp')                          { $sc = 75  }
                elseif($idx -eq $cpuIdx -and $lbl -notmatch 'soc|vrm|board|pch|gpu')                { $sc = 60  }
                elseif($lbl -match '^cpu$')                                                           { $sc = 50  }
                elseif($lbl -match '\bcpu\b' -and $lbl -notmatch 'gpu|ssd|nvme|disk|fan|pch|vrm')  { $sc = 35  }
                if ($sc -gt 0) { $cpuTempC += [PSCustomObject]@{ Score=$sc; Val=[math]::Round($val) } }
            }

            # ══ CPU carga ══
            if ($typ -eq 7 -and $null -eq $s.CpuLoad -and $val -ge 0 -and $val -le 100) {
                $ok = ($idx -eq $cpuIdx -and $lbl -notmatch 'core\s*#\d|thread\s*#\d') -or
                      ($lbl -match 'cpu total|total cpu|cpu usage$|cpu utilization$')
                if ($ok) { $s.CpuLoad = [math]::Round($val) }
            }

            # ══ CPU clock ══
            if ($typ -eq 6 -and $null -eq $s.CpuClk -and $val -gt 100) {
                $ok = ($idx -eq $cpuIdx -and $lbl -notmatch 'bus|ratio|multi|memory|ring|uncore|gpu') -or
                      ($lbl -match 'cpu.*clock$|cpu.*clk$|average.*cpu.*clk')
                if ($ok) { $s.CpuClk = [math]::Round($val) }
            }

            # ══ GPU temperatura ══
            if ($typ -eq 1 -and $val -ge 10 -and $val -lt 115) {
                $sc = 0
                if    ($lbl -eq 'gpu temperature' -or $lbl -match '^gpu temp(erature)?$')            { $sc = 100 }
                elseif($lbl -match 'gpu.*edge|edge.*temp')                                            { $sc = 90  }
                elseif($lbl -match 'gpu.*temp' -and $lbl -notmatch 'hotspot|junction|mem|vram')      { $sc = 80  }
                elseif($lbl -match 'gpu \(t|temperature.*gpu')                                       { $sc = 75  }
                elseif($idx -eq $gpuIdx -and $lbl -notmatch 'hotspot|junction|mem|vram|cpu')        { $sc = 60  }
                elseif($lbl -match '^gpu$')                                                           { $sc = 50  }
                elseif($lbl -match '\bgpu\b' -and $lbl -notmatch 'hotspot|junction|vram|mem\b|cpu') { $sc = 30  }
                if ($sc -gt 0) { $gpuTempC += [PSCustomObject]@{ Score=$sc; Val=[math]::Round($val) } }
            }

            # ══ GPU carga ══
            if ($typ -eq 7 -and $null -eq $s.GpuLoad -and $val -ge 0 -and $val -le 100) {
                $ok = ($idx -eq $gpuIdx -and $lbl -notmatch 'memory|decode|encode|video|bus|uvd|vce|vcn') -or
                      ($lbl -match 'gpu core load|gpu usage$|gpu utilization$|^gpu load$')
                if ($ok) { $s.GpuLoad = [math]::Round($val) }
            }

            # ══ GPU clock ══
            if ($typ -eq 6 -and $val -gt 50) {
                $sc = 0
                if    ($lbl -match '^gpu clock$|^gpu core clock$')                                    { $sc = 100 }
                elseif($lbl -match 'gpu.*core.*clk|gpu core clk$')                                   { $sc = 90  }
                elseif($lbl -match 'gpu.*clock' -and $lbl -notmatch 'mem|video|display')             { $sc = 80  }
                elseif($lbl -match '^core clock$' -and $idx -eq $gpuIdx)                             { $sc = 75  }
                elseif($idx -eq $gpuIdx -and $lbl -notmatch 'mem|video|display|pcie|fan|shader')    { $sc = 50  }
                if ($sc -gt 0) { $gpuClkC += [PSCustomObject]@{ Score=$sc; Val=[math]::Round($val) } }
            }

            # ══ GPU VRAM em MB (Corrigido para Placas AMD D3D) ══
            if ($val -gt 10 -and $val -lt 50000) {
                $sc = 0
                if    ($lbl -match 'd3d memory dedicated|gpu.*mem.*used|gpu memory used|vram used')  { $sc = 100 }
                elseif($lbl -match 'fb memory used|fb.*used')                                        { $sc = 90  }
                elseif($lbl -match 'gpu.*alloc|vram.*alloc')                                         { $sc = 80  }
                elseif($idx -eq $gpuIdx -and $lbl -match 'memory used|mem used|allocated')          { $sc = 70  }
                elseif($lbl -match '\bgpu\b.*\bmem\b' -and $lbl -notmatch 'free|total|avail|band')   { $sc = 50  }
                if ($sc -gt 0 -and $lbl -notmatch 'free|total|avail|bandwidth|system|shared|cpu|dynamic') {
                    $gpuVramC += [PSCustomObject]@{ Score=$sc; Val=[math]::Round($val) }
                }
            }

            # ══ FPS via HWiNFO ══
            if ($null -eq $s.Fps -and $val -gt 0 -and $val -lt 5000) {
                if ($lbl -match 'frame rate|framerate|\bfps\b|frames per') {
                    $s.Fps = [int][math]::Round($val)
                }
            }

            # ══ RAM % ══
            if ($typ -eq 7 -and $null -eq $s.RamPct -and $val -ge 0 -and $val -le 100) {
                if ($lbl -match 'physical memory usage|memory usage$|ram usage$') {
                    $s.RamPct = [math]::Round($val)
                }
            }
        }

        if ($cpuTempC.Count -gt 0) { $s.CpuTemp = ($cpuTempC | Sort-Object Score -Descending | Select-Object -First 1).Val }
        if ($gpuTempC.Count -gt 0) { $s.GpuTemp = ($gpuTempC | Sort-Object Score -Descending | Select-Object -First 1).Val }
        if ($gpuClkC.Count  -gt 0) { $s.GpuClk  = ($gpuClkC  | Sort-Object Score -Descending | Select-Object -First 1).Val }
        if ($gpuVramC.Count -gt 0) { $s.GpuVram = ($gpuVramC | Sort-Object Score -Descending | Select-Object -First 1).Val }
    }

    # ── Fallbacks WMI ──────────────────────────────────────────
    if ($null -eq $s.CpuLoad) {
        try { $s.CpuLoad = [math]::Round(((Get-CimInstance Win32_Processor -EA Stop) |
            Measure-Object -Property LoadPercentage -Average).Average) } catch {}
    }
    if ($null -eq $s.CpuClk) {
        try { $s.CpuClk = [math]::Round(((Get-CimInstance Win32_Processor -EA Stop) |
            Measure-Object -Property CurrentClockSpeed -Average).Average) } catch {}
    }
    if ($null -eq $s.CpuTemp) {
        try {
            $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -EA Stop
            if ($z) { $s.CpuTemp = [math]::Round(($z | Measure-Object -Property CurrentTemperature -Maximum).Maximum / 10 - 273.15) }
        } catch {}
    }
    if ($null -eq $s.GpuLoad) {
        try {
            $eng = Get-Counter '\GPU Engine(*engtype_3D*)\Utilization Percentage' -EA Stop
            $s.GpuLoad = [math]::Round([math]::Min(100, ($eng.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum))
        } catch {
            try {
                $eng = Get-Counter '\GPU Engine(*)\Utilization Percentage' -EA Stop
                $s.GpuLoad = [math]::Round([math]::Min(100, ($eng.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum))
            } catch {}
        }
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -EA Stop
        $usedKB  = $os.TotalVisibleMemorySize - $os.FreePhysicalMemory
        $totalKB = $os.TotalVisibleMemorySize
        $s.RamUsedMB  = [math]::Round($usedKB  / 1KB)
        $s.RamTotalMB = [math]::Round($totalKB / 1KB)
        if ($null -eq $s.RamPct) { $s.RamPct = [math]::Round($usedKB / $totalKB * 100) }
    } catch {}

    return $s
}

# ── Formata RAM ────────────────────────────────────────────────
function Format-Ram($mb) {
    if ($null -eq $mb) { return "---- " }
    if ($mb -ge 1024)  { return "{0:N1} GB" -f ($mb / 1024) }
    return "$mb MB"
}

# ── Formata clock: MHz → GHz ───────────────────────────────────
function Format-Clk($mhz) {
    if ($null -eq $mhz) { return "-.-- GHz" }
    return "{0:N2} GHz" -f ($mhz / 1000)
}

# ── UI ─────────────────────────────────────────────────────────
$degC = [char]176 + "C"
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "System Monitor"
$form.ClientSize      = New-Object System.Drawing.Size(1280, 400)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor       = [System.Drawing.Color]::FromArgb(10, 10, 16)
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost         = $true

# Remove o aplicativo da barra de tarefas principal
$form.ShowInTaskbar   = $false 

$target = [System.Windows.Forms.Screen]::AllScreens |
    Where-Object { $_.Bounds.Width -eq 1280 -and $_.Bounds.Height -eq 400 } | Select-Object -First 1
$script:_lockedPos = if ($target) { $target.Bounds.Location } else { New-Object System.Drawing.Point(0,0) }
$form.Location = $script:_lockedPos

function New-Lbl($text, $pt, $x, $y, $r, $g, $b, [switch]$thin) {
    $l        = New-Object System.Windows.Forms.Label
    $l.Text   = $text
    $style    = if ($thin) { [System.Drawing.FontStyle]::Regular } else { [System.Drawing.FontStyle]::Bold }
    $l.Font   = New-Object System.Drawing.Font("Segoe UI", $pt, $style)
    $l.ForeColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
    $l.AutoSize  = $true
    $l.Location  = New-Object System.Drawing.Point($x, $y)
    $form.Controls.Add($l); return $l
}
function New-Bar($x, $y, $w, $h, $r, $g, $b) {
    $out = New-Object System.Windows.Forms.Panel
    $out.Size      = New-Object System.Drawing.Size($w, $h)
    $out.Location  = New-Object System.Drawing.Point($x, $y)
    $out.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 45)
    $form.Controls.Add($out)
    $in = New-Object System.Windows.Forms.Panel
    $in.Size      = New-Object System.Drawing.Size(0, $h)
    $in.Location  = New-Object System.Drawing.Point(0, 0)
    $in.BackColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
    $out.Controls.Add($in)
    return @{ bar=$in; max=$w }
}
function Set-Bar($b, $val, $maxVal = 100) {
    if ($null -eq $val) { return }
    $pct = [math]::Max(0, [math]::Min(100, $val / $maxVal * 100))
    $b.bar.Width = [int]($pct / 100 * $b.max)
}

foreach ($dx in @(330, 660, 980)) {
    $sep = New-Object System.Windows.Forms.Panel
    $sep.Size      = New-Object System.Drawing.Size(1, 360)
    $sep.Location  = New-Object System.Drawing.Point($dx, 20)
    $sep.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 60)
    $form.Controls.Add($sep)
}

# ── CPU ──────────────────────────────────────────────────────
New-Lbl "CPU"              9  30 20  100 100 130       | Out-Null
$lCpuName = New-Lbl "AMD Ryzen 5 5600X" 9 30 38 150 150 180 -thin
New-Lbl "TEMP"  8  30 88  80  80 110 -thin | Out-Null
New-Lbl "LOAD"  8 175 88  80  80 110 -thin | Out-Null
$lCpuTemp = New-Lbl "--$degC"   40  30 100  0 200 255
$lCpuLoad = New-Lbl "-- %"      40 175 100  0 200 255
New-Lbl "CLOCK" 8  30 230  80  80 110 -thin | Out-Null
$lCpuClk  = New-Lbl "-.-- GHz"  18  30 244  0 170 220 -thin
$bCpuT = New-Bar  30 320 130 12   0 170 210
$bCpuL = New-Bar 175 320 130 12   0 170 210
New-Lbl "TEMP"  7  30 334  60 60 90 -thin | Out-Null
New-Lbl "LOAD"  7 175 334  60 60 90 -thin | Out-Null

# ── GPU ──────────────────────────────────────────────────────
New-Lbl "GPU"              9 355 20  100 100 130       | Out-Null
$lGpuName = New-Lbl "AMD RX 7800 XT"  9 355 38 150 150 180 -thin
New-Lbl "TEMP"  8 355 88  80  80 110 -thin | Out-Null
New-Lbl "LOAD"  8 500 88  80  80 110 -thin | Out-Null
$lGpuTemp = New-Lbl "--$degC"   40 355 100  40 215 95
$lGpuLoad = New-Lbl "-- %"      40 500 100  40 215 95
New-Lbl "VRAM"  8 355 230  80  80 110 -thin | Out-Null
New-Lbl "CLOCK" 8 500 230  80  80 110 -thin | Out-Null
$lGpuVram = New-Lbl "---- MB"   18 355 244  40 185 80 -thin
$lGpuClk  = New-Lbl "-.-- GHz"  18 500 244  40 185 80 -thin
$bGpuT = New-Bar 355 320 130 12  40 185 75
$bGpuL = New-Bar 500 320 130 12  40 185 75
New-Lbl "TEMP"  7 355 334  60 60 90 -thin | Out-Null
New-Lbl "LOAD"  7 500 334  60 60 90 -thin | Out-Null

# ── RAM ──────────────────────────────────────────────────────
New-Lbl "RAM"              9 685 20  100 100 130       | Out-Null
New-Lbl "USADO"  8 685 88   80  80 110 -thin | Out-Null
$lRamMB  = New-Lbl "---- GB"   32 685 100  255 155 0
New-Lbl "TOTAL"  8 685 180   80  80 110 -thin | Out-Null
$lRamTot = New-Lbl "---- GB"   18 685 194  200 120  0 -thin
New-Lbl "USO %"  8 685 230   80  80 110 -thin | Out-Null
$lRamPct = New-Lbl "-- %"      32 685 244  255 155  0
$bRam = New-Bar 685 320 270 12  220 125 0
New-Lbl "USAGE"  7 685 334  60 60 90 -thin | Out-Null

# ── FPS + Gráfico de Frametime ────────────────────────────────
New-Lbl "FPS"       9 1005 20  100 100 130      | Out-Null
$lFps  = New-Lbl "---"  56 1005 55  255 220 60
New-Lbl "frames/s"  8 1005 155 100  80  40 -thin | Out-Null
$lFtMs = New-Lbl "-- ms" 8 1140 155  90  70  30 -thin

$sepFt = New-Object System.Windows.Forms.Panel
$sepFt.Size      = New-Object System.Drawing.Size(258, 1)
$sepFt.Location  = New-Object System.Drawing.Point(1008, 170)
$sepFt.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 55)
$form.Controls.Add($sepFt)

$ftPanel = New-Object System.Windows.Forms.Panel
$ftPanel.Size      = New-Object System.Drawing.Size(258, 130)
$ftPanel.Location  = New-Object System.Drawing.Point(1008, 172)
$ftPanel.BackColor = [System.Drawing.Color]::FromArgb(14, 14, 22)
$form.Controls.Add($ftPanel)

New-Lbl "60fps"     6 1242 174  50 50 72 -thin | Out-Null
New-Lbl "30fps"     6 1242 215  50 50 72 -thin | Out-Null
New-Lbl "FRAMETIME" 6 1008 306  55 55 80 -thin | Out-Null

$script:_ftHistory = New-Object System.Collections.Generic.List[double]
$script:_ftMaxSamp = 120

$ftPanel.Add_Paint({
    param($sender, $e)
    $g  = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pw = $sender.Width
    $ph = $sender.Height
    $n  = $script:_ftHistory.Count

    $g.Clear([System.Drawing.Color]::FromArgb(14, 14, 22))

    $maxFt  = 50.0
    $y60    = [int]($ph - ($ph * 16.67 / $maxFt))
    $y30    = [int]($ph - ($ph * 33.33 / $maxFt))
    $penRef = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 40, 62))
    $g.DrawLine($penRef, 0, $y60, $pw, $y60)
    $g.DrawLine($penRef, 0, $y30, $pw, $y30)
    $penRef.Dispose()

    if ($n -lt 2) { return }

    $pts = New-Object 'System.Drawing.PointF[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $x       = [float]($i * ($pw - 1) / ($n - 1))
        $yFrac   = [math]::Min($script:_ftHistory[$i] / $maxFt, 1.0)
        $y       = [float]($ph - $yFrac * ($ph - 2) - 1)
        $pts[$i] = [System.Drawing.PointF]::new($x, $y)
    }

    $worstFt = ($script:_ftHistory | Select-Object -Last 20 | Measure-Object -Maximum).Maximum
    $lineClr = if ($worstFt -gt 33.33) {
        [System.Drawing.Color]::FromArgb(255,  80, 55)
    } elseif ($worstFt -gt 25.0) {
        [System.Drawing.Color]::FromArgb(255, 175, 40)
    } else {
        [System.Drawing.Color]::FromArgb(255, 215, 55)
    }
    $pen = New-Object System.Drawing.Pen($lineClr, 1.5)
    $g.DrawLines($pen, $pts)
    $pen.Dispose()
})

# ── Status bar ───────────────────────────────────────────────
$lStatus = New-Object System.Windows.Forms.Label
$lStatus.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lStatus.ForeColor = [System.Drawing.Color]::FromArgb(55, 55, 75)
$lStatus.AutoSize  = $true
$lStatus.Location  = New-Object System.Drawing.Point(10, 382)
$form.Controls.Add($lStatus)

$script:_snapping = $false
$form.Add_LocationChanged({
    if (-not $script:_snapping -and $form.Location -ne $script:_lockedPos) {
        $script:_snapping = $true
        $form.Location    = $script:_lockedPos
        $script:_snapping = $false
    }
})

# ── Ícone na Bandeja do Sistema (System Tray) e Função de Fechar ──

# Criação do ícone oculto perto do relógio
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
try { 
    # Extrai o ícone nativo do seu .exe ou do PowerShell
    $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) 
} catch {}
$notifyIcon.Text = "System Monitor"
$notifyIcon.Visible = $true

# Função centralizada para fechar tudo de forma limpa
function Close-App {
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $form.Close()
}

# Menu de clique direito no ícone da bandeja
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$mnuTrayClose = $trayMenu.Items.Add("Fechar Monitor")
$mnuTrayClose.add_Click({ Close-App })
$notifyIcon.ContextMenuStrip = $trayMenu

# Atalhos
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Close-App } })
$form.Add_DoubleClick({ Close-App })

$ctx      = New-Object System.Windows.Forms.ContextMenuStrip
$mnuClose = $ctx.Items.Add("Fechar")
$mnuClose.add_Click({ Close-App })
$form.ContextMenuStrip = $ctx

# ── Timer e loop de atualização ──────────────────────────────
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000

$updateUI = {
    try {
        $st = Get-SystemStats

        $lCpuName.Text = $st.CpuName
        if ($null -ne $st.CpuTemp) { 
            $lCpuTemp.Text = "$($st.CpuTemp)$degC"
            if ($st.CpuTemp -gt 80) { 
                $lCpuTemp.ForeColor = [System.Drawing.Color]::Red 
            } else { 
                $lCpuTemp.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 255)
            }
        } else { 
            $lCpuTemp.Text = "N/A"
            $lCpuTemp.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 255)
        }
        
        $lCpuLoad.Text = if ($null -ne $st.CpuLoad) { "$($st.CpuLoad) %" }   else { "N/A" }
        $lCpuClk.Text  = Format-Clk $st.CpuClk
        Set-Bar $bCpuT $st.CpuTemp 100
        Set-Bar $bCpuL $st.CpuLoad

        $lGpuName.Text = $st.GpuName
        if ($null -ne $st.GpuTemp) { 
            $lGpuTemp.Text = "$($st.GpuTemp)$degC"
            if ($st.GpuTemp -gt 80) { 
                $lGpuTemp.ForeColor = [System.Drawing.Color]::Red 
            } else { 
                $lGpuTemp.ForeColor = [System.Drawing.Color]::FromArgb(40, 215, 95)
            }
        } else { 
            $lGpuTemp.Text = "N/A"
            $lGpuTemp.ForeColor = [System.Drawing.Color]::FromArgb(40, 215, 95)
        }

        $lGpuLoad.Text = if ($null -ne $st.GpuLoad) { "$($st.GpuLoad) %" }   else { "N/A" }
        $lGpuVram.Text = if ($null -ne $st.GpuVram) { "$($st.GpuVram) MB" }  else { "--- MB" }
        $lGpuClk.Text  = Format-Clk $st.GpuClk
        Set-Bar $bGpuT $st.GpuTemp 110
        Set-Bar $bGpuL $st.GpuLoad

        if ($null -ne $st.RamUsedMB) {
            $lRamMB.Text  = Format-Ram $st.RamUsedMB
            $lRamTot.Text = Format-Ram $st.RamTotalMB
            $lRamPct.Text = "$($st.RamPct) %"
            Set-Bar $bRam $st.RamPct
        }

        if ($null -ne $st.Fps -and $st.Fps -gt 0) {
            $lFps.Text  = "$($st.Fps)"
            $ft = [math]::Round(1000.0 / $st.Fps, 1)
            $lFtMs.Text = "$ft ms"
            $script:_ftHistory.Add([double]$ft)
            while ($script:_ftHistory.Count -gt $script:_ftMaxSamp) { $script:_ftHistory.RemoveAt(0) }
            $ftPanel.Invalidate()
        } else {
            $lFps.Text  = "---"
            $lFtMs.Text = "-- ms"
        }

        $lStatus.ForeColor = if ($st.Source -eq "HWiNFO64") {
            [System.Drawing.Color]::FromArgb(45, 150, 45)
        } else { [System.Drawing.Color]::FromArgb(160, 120, 0) }
        $rtssOk = if ($null -ne $st.Fps) { "  |  RTSS OK" } else { "" }
        $lStatus.Text = "$(Get-Date -Format 'HH:mm:ss')  |  $($st.Source)$rtssOk"

    } catch {
        $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $lStatus.Text = "ERRO: $($_.Exception.Message)"
    }
}

$timer.Add_Tick($updateUI)
$timer.Start()
& $updateUI

[System.Windows.Forms.Application]::Run($form)
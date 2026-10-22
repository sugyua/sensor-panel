Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'Painel.log'

function Write-PanelLog {
    param([string]$Message)
    Add-Content -LiteralPath $logPath -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

try {
    $matchingScreens = @([System.Windows.Forms.Screen]::AllScreens | Where-Object {
        -not $_.Primary -and $_.Bounds.Width -eq 1280 -and $_.Bounds.Height -eq 400
    })

    if ($matchingScreens.Count -ne 1) {
        $message = if ($matchingScreens.Count -eq 0) {
            'Painel nao iniciado: nao foi encontrado um monitor secundario com resolucao de 1280x400.'
        } else {
            'Painel nao iniciado: mais de um monitor secundario de 1280x400 foi encontrado.'
        }
        throw $message
    }

    $targetScreen = $matchingScreens[0]
    $script:fpsHistory = New-Object 'System.Collections.Generic.List[object]'
    $script:fpsHistorySeconds = 30
    $script:degC = [char]176 + 'C'

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO.MemoryMappedFiles;
using System.Text;

public sealed class PanelReading {
    public string Label;
    public string Unit;
    public double Value;
    public uint SensorIndex;
    public uint Type;
}

public sealed class PanelSensor {
    public string Name;
}

public static class PanelHWiNFO {
    private const string SharedMemory = "Global\\HWiNFO_SENS_SM2";

    public static bool IsRunning() {
        try {
            using (MemoryMappedFile.OpenExisting(SharedMemory)) { }
            return true;
        } catch { return false; }
    }

    public static List<PanelReading> Read(out List<PanelSensor> sensors) {
        sensors = new List<PanelSensor>();
        var readings = new List<PanelReading>();
        try {
            using (var map = MemoryMappedFile.OpenExisting(SharedMemory))
            using (var view = map.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                if (view.ReadUInt32(0) != 0x53695748) return readings;
                uint sensorOffset = view.ReadUInt32(20);
                uint sensorSize = view.ReadUInt32(24);
                uint sensorCount = view.ReadUInt32(28);
                uint readingOffset = view.ReadUInt32(32);
                uint readingSize = view.ReadUInt32(36);
                uint readingCount = view.ReadUInt32(40);
                byte[] text = new byte[128];
                byte[] unit = new byte[16];

                for (uint i = 0; i < sensorCount; i++) {
                    long address = sensorOffset + i * sensorSize;
                    view.ReadArray(address + 8, text, 0, text.Length);
                    sensors.Add(new PanelSensor {
                        Name = Encoding.UTF8.GetString(text).TrimEnd('\0')
                    });
                }

                for (uint i = 0; i < readingCount; i++) {
                    long address = readingOffset + i * readingSize;
                    var item = new PanelReading();
                    item.Type = view.ReadUInt32(address);
                    item.SensorIndex = view.ReadUInt32(address + 4);
                    view.ReadArray(address + 12, text, 0, text.Length);
                    item.Label = Encoding.UTF8.GetString(text).TrimEnd('\0');
                    view.ReadArray(address + 268, unit, 0, unit.Length);
                    item.Unit = Encoding.UTF8.GetString(unit).TrimEnd('\0');
                    item.Value = view.ReadDouble(address + 284);
                    readings.Add(item);
                }
            }
        } catch { }
        return readings;
    }
}

public sealed class AfterburnerReading {
    public string Name;
    public string Unit;
    public float Value;
    public uint GpuIndex;
    public uint SourceId;
}

public sealed class AfterburnerGpu {
    public string Name;
    public string Id;
}

public static class AfterburnerReader {
    private const string SharedMemory = "MAHMSharedMemory";
    private const uint Signature = 0x4D41484D;
    private const uint Version = 0x00020000;
    private const uint MaxEntries = 4096;
    private const uint MaxGpus = 64;
    private const uint EntrySize = 1324;
    private const uint GpuEntrySize = 1304;

    private static string ReadText(MemoryMappedViewAccessor view, long offset, int length) {
        byte[] bytes = new byte[length];
        view.ReadArray(offset, bytes, 0, length);
        int terminator = Array.IndexOf(bytes, (byte)0);
        return Encoding.ASCII.GetString(bytes, 0, terminator < 0 ? bytes.Length : terminator).Trim();
    }

    public static bool IsAvailable() {
        try {
            using (MemoryMappedFile.OpenExisting(SharedMemory, MemoryMappedFileRights.Read)) {
                return true;
            }
        } catch {
            return false;
        }
    }

    public static List<AfterburnerReading> Read(out List<AfterburnerGpu> gpus) {
        gpus = new List<AfterburnerGpu>();
        var readings = new List<AfterburnerReading>();
        using (var map = MemoryMappedFile.OpenExisting(SharedMemory, MemoryMappedFileRights.Read))
        using (var view = map.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
            if (view.Capacity < 32 || view.ReadUInt32(0) != Signature)
                throw new InvalidOperationException("A interface do Afterburner nao esta inicializada.");
            uint version = view.ReadUInt32(4);
            uint headerSize = view.ReadUInt32(8);
            uint count = view.ReadUInt32(12);
            uint entrySize = view.ReadUInt32(16);
            uint gpuCount = view.ReadUInt32(24);
            uint gpuEntrySize = view.ReadUInt32(28);
            if (version < Version || headerSize < 32 || headerSize > view.Capacity ||
                count > MaxEntries || gpuCount > MaxGpus ||
                (count > 0 && entrySize != EntrySize) ||
                (gpuCount > 0 && gpuEntrySize != GpuEntrySize))
                throw new InvalidOperationException("Formato da interface de monitoramento do Afterburner nao suportado.");

            long entriesOffset = headerSize;
            long gpuOffset = entriesOffset + (long)count * entrySize;
            long endOffset = gpuOffset + (long)gpuCount * gpuEntrySize;
            if (endOffset > view.Capacity)
                throw new InvalidOperationException("Dados de monitoramento do Afterburner incompletos.");

            for (uint i = 0; i < count; i++) {
                long address = entriesOffset + (long)i * entrySize;
                float value = view.ReadSingle(address + 1300);
                if (float.IsNaN(value) || float.IsInfinity(value) || Math.Abs(value) >= 1.0e30f)
                    continue;
                readings.Add(new AfterburnerReading {
                    Name = ReadText(view, address, 260),
                    Unit = ReadText(view, address + 260, 260),
                    Value = value,
                    GpuIndex = view.ReadUInt32(address + 1316),
                    SourceId = view.ReadUInt32(address + 1320)
                });
            }

            for (uint i = 0; i < gpuCount; i++) {
                long address = gpuOffset + (long)i * gpuEntrySize;
                gpus.Add(new AfterburnerGpu {
                    Id = ReadText(view, address, 260),
                    Name = ReadText(view, address + 520, 260)
                });
            }
        }
        return readings;
    }
}

'@

    function Get-NetworkRates {
        $interfaces = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object {
                $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
                $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -and
                $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel
            })
        $current = @{}
        $errors = @()

        foreach ($interface in $interfaces) {
            try {
                $statistics = $interface.GetIPStatistics()
                $current[$interface.Id] = @{
                    Received = [double]$statistics.BytesReceived
                    Sent = [double]$statistics.BytesSent
                }
            } catch {
                $errors += '{0}: {1}' -f $interface.Name, $_.Exception.Message
            }
        }

        if ($errors.Count -gt 0) {
            $script:previousNetworkSample = $null
            return [pscustomobject]@{
                DownloadMbps = $null
                UploadMbps = $null
                Error = 'Erro ao ler interfaces de rede: ' + ($errors -join '; ')
            }
        }
        if ($current.Count -eq 0) {
            $script:previousNetworkSample = $null
            return [pscustomobject]@{
                DownloadMbps = $null
                UploadMbps = $null
                Error = 'Nenhuma interface de rede ativa.'
            }
        }

        $sampleTime = [DateTime]::UtcNow
        $downloadMbps = $null
        $uploadMbps = $null
        if ($null -ne $script:previousNetworkSample) {
            $elapsed = ($sampleTime - $script:previousNetworkSample.Time).TotalSeconds
            if ($elapsed -gt 0) {
                $receivedBytes = 0.0
                $sentBytes = 0.0
                $hasComparableInterface = $false
                foreach ($id in $current.Keys) {
                    if (-not $script:previousNetworkSample.Counters.ContainsKey($id)) { continue }
                    $receivedDelta = $current[$id].Received - $script:previousNetworkSample.Counters[$id].Received
                    $sentDelta = $current[$id].Sent - $script:previousNetworkSample.Counters[$id].Sent
                    if ($receivedDelta -lt 0 -or $sentDelta -lt 0) { continue }
                    $receivedBytes += $receivedDelta
                    $sentBytes += $sentDelta
                    $hasComparableInterface = $true
                }
                if ($hasComparableInterface) {
                    $downloadMbps = ($receivedBytes * 8) / ($elapsed * 1000000)
                    $uploadMbps = ($sentBytes * 8) / ($elapsed * 1000000)
                }
            }
        }
        $script:previousNetworkSample = @{ Time = $sampleTime; Counters = $current }

        return [pscustomobject]@{
            DownloadMbps = $downloadMbps
            UploadMbps = $uploadMbps
            Error = ''
        }
    }

    function Get-PanelStats {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $videoControllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
        $gpu = $videoControllers |
            Where-Object {
                $_.Name -notmatch 'Parsec|Virtual|Remote Display|Microsoft Basic|Indirect Display'
            } |
            Sort-Object @{ Expression = { if ($_.PNPDeviceID -like 'PCI\*') { 0 } else { 1 } } } |
            Select-Object -First 1

        $stats = [ordered]@{
            CpuName = if ($cpu) { $cpu.Name.Trim() } else { 'Processador' }
            CpuTemp = $null; CpuLoad = $null; CpuClock = $null
            GpuName = if ($gpu) { $gpu.Name.Trim() } else { 'Placa de video' }
            GpuTemp = $null; GpuLoad = $null; GpuClock = $null; GpuVram = $null
            RamUsed = $null; RamTotal = $null; RamPercent = $null
            Fps = $null; Frametime = $null; Source = 'WMI'; SensorStatus = ''
        }

        if ($cpu) {
            $stats.CpuLoad = [math]::Round($cpu.LoadPercentage)
            if ($cpu.CurrentClockSpeed) { $stats.CpuClock = [double]$cpu.CurrentClockSpeed }
        }

        if ($os -and $os.TotalVisibleMemorySize -gt 0) {
            $total = [double]$os.TotalVisibleMemorySize
            $used = $total - [double]$os.FreePhysicalMemory
            $stats.RamTotal = [math]::Round($total / 1MB, 1)
            $stats.RamUsed = [math]::Round($used / 1MB, 1)
            $stats.RamPercent = [math]::Round(($used / $total) * 100)
        }

        $hwinfoRunning = @(Get-Process -Name HWiNFO64,HWiNFO -ErrorAction SilentlyContinue).Count -gt 0
        $sharedMemoryAvailable = [PanelHWiNFO]::IsRunning()
        $stats.HWiNFOPresent = $hwinfoRunning
        $stats.SharedMemoryAvailable = $sharedMemoryAvailable
        if ($sharedMemoryAvailable) {
            $stats.Source = 'HWiNFO64 + WMI'
            $sensors = $null
            $readings = [PanelHWiNFO]::Read([ref]$sensors)
            $cpuIndex = -1
            $gpuIndex = -1

            for ($i = 0; $i -lt $sensors.Count; $i++) {
                $name = $sensors[$i].Name
                if ($cpuIndex -lt 0 -and $name -match 'ryzen|processor|cpu') { $cpuIndex = $i }
                if ($gpuIndex -lt 0 -and $name -match 'radeon|geforce|rx \d|gtx|rtx|gpu') { $gpuIndex = $i }
            }

            $cpuTemps = @()
            $gpuTemps = @()
            $gpuClocks = @()
            foreach ($reading in $readings) {
                $label = $reading.Label.ToLowerInvariant()
                $index = [int]$reading.SensorIndex
                $value = $reading.Value
                if ($reading.Type -eq 1 -and $value -ge 10 -and $value -lt 115) {
                    if (($index -eq $cpuIndex -or $label -match 'cpu|tctl|tdie') -and
                        $label -notmatch 'gpu|soc|vrm|board|pch') {
                        $score = if ($label -match 'tdie|tctl') { 3 } else { 1 }
                        $cpuTemps += [pscustomobject]@{ Score = $score; Value = [math]::Round($value) }
                    }
                    if (($index -eq $gpuIndex -or $label -match 'gpu') -and
                        $label -match 'gpu|edge' -and $label -notmatch 'hotspot|junction|memory|vram') {
                        $score = if ($label -match '^gpu temp|gpu temperature') { 3 } else { 1 }
                        $gpuTemps += [pscustomobject]@{ Score = $score; Value = [math]::Round($value) }
                    }
                }

                if ($reading.Type -eq 7 -and $value -ge 0 -and $value -le 100) {
                    if ($null -eq $stats.CpuLoad -or $stats.CpuLoad -eq 0) {
                        if (($index -eq $cpuIndex -and $label -notmatch 'core\s*#?\d|thread') -or
                            $label -match 'cpu total|total cpu|cpu usage$|cpu utilization$') {
                            $stats.CpuLoad = [math]::Round($value)
                        }
                    }
                    if (($index -eq $gpuIndex -and $label -notmatch 'memory|decode|encode|video') -or
                        $label -match 'gpu core load|gpu usage$|gpu utilization$|^gpu load$') {
                        $stats.GpuLoad = [math]::Round($value)
                    }
                    if ($label -match 'physical memory usage|memory usage$|ram usage$') {
                        $stats.RamPercent = [math]::Round($value)
                    }
                }

                if ($reading.Type -eq 6 -and $value -gt 50) {
                    if ((($index -eq $cpuIndex -or $label -match 'cpu.*clock|cpu.*clk') -and
                        $label -notmatch 'bus|memory|ring|uncore|gpu') -and $null -eq $stats.CpuClock) {
                        $stats.CpuClock = [double]$value
                    }
                    if (($index -eq $gpuIndex -and $label -notmatch 'memory|video|display|pcie') -or
                        $label -match '^gpu.*clock|gpu.*core.*clk') {
                        $gpuClocks += [double]$value
                    }
                }

                if ($value -gt 10 -and $value -lt 50000 -and
                    $label -match 'd3d memory dedicated|gpu.*mem.*used|gpu memory used|vram used|fb memory used') {
                    if ($reading.Unit -match 'GB') { $stats.GpuVram = [math]::Round($value * 1024) }
                    else { $stats.GpuVram = [math]::Round($value) }
                }

                if ($null -eq $stats.Fps -and $value -gt 0 -and $value -lt 5000 -and
                    $label -match 'frame rate|framerate|\bfps\b|frames per') {
                    $stats.Fps = [math]::Round($value)
                }
            }

            if ($cpuTemps.Count) {
                $stats.CpuTemp = ($cpuTemps | Sort-Object Score -Descending | Select-Object -First 1).Value
            }
            if ($gpuTemps.Count) {
                $stats.GpuTemp = ($gpuTemps | Sort-Object Score -Descending | Select-Object -First 1).Value
            }
            if ($gpuClocks.Count) {
                $stats.GpuClock = [double](($gpuClocks | Measure-Object -Maximum).Maximum)
            }
        } else {
            $thermalZones = @(Get-CimInstance -Namespace root/wmi `
                -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue)
            $cpuTemperature = $thermalZones |
                Where-Object { $_.CurrentTemperature -ge 2932 -and $_.CurrentTemperature -le 3832 } |
                Measure-Object -Property CurrentTemperature -Maximum
            if ($cpuTemperature.Count -gt 0 -and $null -ne $cpuTemperature.Maximum) {
                $stats.CpuTemp = [math]::Round(($cpuTemperature.Maximum / 10) - 273.15)
            }

            if ($hwinfoRunning) {
                $stats.SensorStatus = 'HWiNFO aberto sem sensores: abra Sensors e ative Shared Memory Support.'
            } else {
                $stats.SensorStatus = 'Abra o HWiNFO64 e ative Shared Memory Support para ler temperaturas.'
            }
        }

        if ([AfterburnerReader]::IsAvailable()) {
            try {
                $afterburnerGpus = $null
                $afterburnerReadings = [AfterburnerReader]::Read([ref]$afterburnerGpus)
                $afterburnerGpuIndex = -1
                for ($i = 0; $i -lt $afterburnerGpus.Count; $i++) {
                    if ($gpu -and $afterburnerGpus[$i].Name -eq $gpu.Name.Trim()) {
                        $afterburnerGpuIndex = $i
                        break
                    }
                }
                if ($afterburnerGpuIndex -lt 0 -and $afterburnerGpus.Count -gt 0) {
                    $afterburnerGpuIndex = 0
                }

                $globalReadings = @($afterburnerReadings | Where-Object {
                    $_.GpuIndex -eq [uint32]::MaxValue
                })
                $gpuReadings = @($afterburnerReadings | Where-Object {
                    $_.GpuIndex -eq $afterburnerGpuIndex
                })
                $cpuTempReading = $globalReadings | Where-Object SourceId -eq 0x80 | Select-Object -First 1
                $cpuLoadReading = $globalReadings | Where-Object SourceId -eq 0x90 | Select-Object -First 1
                $cpuClockReading = $globalReadings | Where-Object SourceId -eq 0xA0 | Select-Object -First 1
                $gpuTempReading = $gpuReadings | Where-Object SourceId -eq 0x00 | Select-Object -First 1
                $gpuLoadReading = $gpuReadings | Where-Object SourceId -eq 0x30 | Select-Object -First 1
                $gpuMemoryReading = $gpuReadings | Where-Object SourceId -eq 0x31 | Select-Object -First 1
                $gpuClockReading = $gpuReadings | Where-Object SourceId -eq 0x20 | Select-Object -First 1
                $ramReading = $afterburnerReadings | Where-Object SourceId -eq 0x91 | Select-Object -First 1
                $fpsReading = $globalReadings | Where-Object SourceId -eq 0x50 | Select-Object -First 1
                $frametimeReading = $afterburnerReadings |
                    Where-Object { $_.SourceId -eq 0x51 -and $_.Value -gt 0 -and $_.Value -lt 10000 } |
                    Sort-Object @{ Expression = { if ($_.GpuIndex -eq [uint32]::MaxValue) { 0 } else { 1 } } } |
                    Select-Object -First 1

                if ($cpuTempReading -and $cpuTempReading.Value -ge 0 -and $cpuTempReading.Value -lt 150) {
                    $stats.CpuTemp = [math]::Round($cpuTempReading.Value)
                }
                if ($cpuLoadReading -and $cpuLoadReading.Value -ge 0 -and $cpuLoadReading.Value -le 100) {
                    $stats.CpuLoad = [math]::Round($cpuLoadReading.Value)
                }
                if ($cpuClockReading -and $cpuClockReading.Value -gt 0) {
                    $stats.CpuClock = [double]$cpuClockReading.Value
                }
                if ($afterburnerGpuIndex -ge 0) {
                    if ($afterburnerGpus[$afterburnerGpuIndex].Name) {
                        $stats.GpuName = $afterburnerGpus[$afterburnerGpuIndex].Name
                    }
                    if ($gpuTempReading -and $gpuTempReading.Value -ge 0 -and $gpuTempReading.Value -lt 150) {
                        $stats.GpuTemp = [math]::Round($gpuTempReading.Value)
                    }
                    if ($gpuLoadReading -and $gpuLoadReading.Value -ge 0 -and $gpuLoadReading.Value -le 100) {
                        $stats.GpuLoad = [math]::Round($gpuLoadReading.Value)
                    }
                    if ($gpuClockReading -and $gpuClockReading.Value -gt 0) {
                        $stats.GpuClock = [double]$gpuClockReading.Value
                    }
                    if ($gpuMemoryReading -and $gpuMemoryReading.Value -ge 0) {
                        $stats.GpuVram = [math]::Round($gpuMemoryReading.Value)
                    }
                }
                if ($ramReading -and $ramReading.Value -ge 0 -and $ramReading.Unit -match 'MB') {
                    $stats.RamUsed = [math]::Round($ramReading.Value / 1024, 1)
                    if ($stats.RamTotal -gt 0) {
                        $stats.RamPercent = [math]::Round(($stats.RamUsed / $stats.RamTotal) * 100)
                    }
                }
                if ($fpsReading -and $fpsReading.Value -gt 0 -and $fpsReading.Value -lt 5000) {
                    $stats.Fps = [math]::Round($fpsReading.Value)
                }
                if ($frametimeReading -and $frametimeReading.Value -gt 0 -and $frametimeReading.Value -lt 10000) {
                    $stats.Frametime = [math]::Round($frametimeReading.Value, 1)
                } elseif ($fpsReading -and $fpsReading.Value -gt 0 -and $fpsReading.Value -lt 5000) {
                    $stats.Frametime = [math]::Round(1000 / $fpsReading.Value, 1)
                }
                $stats.Source = 'MSI Afterburner'
                $stats.SensorStatus = ''
            } catch {
                $stats.SensorStatus = 'Erro ao ler MSI Afterburner: ' + $_.Exception.Message
            }
        } elseif ($stats.Source -eq 'WMI') {
            $stats.SensorStatus = 'Abra o MSI Afterburner e ative os sensores na aba Monitoring.'
        }

        $hasVirtualDisplay = @($videoControllers | Where-Object {
            $_.Name -match 'Parsec|Virtual|Remote Display|Indirect Display'
        }).Count -gt 0
        if ($null -eq $stats.GpuLoad -and -not $hasVirtualDisplay) {
            try {
                $counter = Get-Counter '\GPU Engine(*engtype_3D*)\Utilization Percentage' -ErrorAction Stop
                $stats.GpuLoad = [math]::Round([math]::Min(100,
                    ($counter.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum))
            } catch { }
        }

        return [pscustomobject]$stats
    }

    function New-PanelLabel {
        param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Size,
              [System.Drawing.Color]$Color, [switch]$Bold, [int]$Width = 260)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point($X, $Y)
        $height = [math]::Max(($Size + 7), [math]::Ceiling($Size * 1.55) + 4)
        $label.Size = New-Object System.Drawing.Size($Width, $height)
        $label.ForeColor = $Color
        $label.BackColor = [System.Drawing.Color]::Transparent
        $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size,
            $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
        $label.AutoEllipsis = $true
        $Parent.Controls.Add($label)
        return $label
    }

    function New-ProgressBar {
        param($Parent, [int]$X, [int]$Y, [int]$Width, [System.Drawing.Color]$Color)
        $track = New-Object System.Windows.Forms.Panel
        $track.Location = New-Object System.Drawing.Point($X, $Y)
        $track.Size = New-Object System.Drawing.Size($Width, 5)
        $track.BackColor = [System.Drawing.Color]::FromArgb(31, 37, 47)
        $Parent.Controls.Add($track)
        $fill = New-Object System.Windows.Forms.Panel
        $fill.Size = New-Object System.Drawing.Size(0, 5)
        $fill.BackColor = $Color
        $track.Controls.Add($fill)
        return @{ Track = $track; Fill = $fill; Color = $Color }
    }

    function Set-Progress {
        param($Bar, $Value)
        $width = 0
        if ($null -ne $Value) {
            $width = [int]($Bar.Track.Width * [math]::Max(0, [math]::Min(100, [double]$Value)) / 100)
        }
        $Bar.Fill.Width = $width
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Painel de Sensores'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = $targetScreen.Bounds.Location
    $form.ClientSize = New-Object System.Drawing.Size(1280, 400)
    $form.BackColor = [System.Drawing.Color]::Black
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.KeyPreview = $true

    $palette = @{
        Text = [System.Drawing.Color]::FromArgb(233, 239, 246)
        Muted = [System.Drawing.Color]::FromArgb(119, 134, 150)
        Cyan = [System.Drawing.Color]::FromArgb(40, 208, 220)
        Green = [System.Drawing.Color]::FromArgb(104, 222, 157)
        Orange = [System.Drawing.Color]::FromArgb(255, 181, 82)
        Red = [System.Drawing.Color]::FromArgb(255, 102, 112)
        Hot = [System.Drawing.Color]::FromArgb(255, 0, 0)
    }

    $cardSpecs = @(
        @{ X = 24; Title = 'Ryzen 5 5600X'; Subtitle = ''; Accent = $palette.Cyan },
        @{ X = 336; Title = 'AMD RX 7800 XT'; Subtitle = ''; Accent = $palette.Green },
        @{ X = 648; Title = 'Memória'; Subtitle = 'Utilização da memória'; Accent = $palette.Orange },
        @{ X = 960; Title = 'Desempenho'; Subtitle = 'FPS em tempo real'; Accent = $palette.Hot }
    )
    $cards = @()
    foreach ($spec in $cardSpecs) {
        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point($spec.X, 10)
        $card.Size = New-Object System.Drawing.Size(296, 282)
        $card.BackColor = [System.Drawing.Color]::Black
        $form.Controls.Add($card)
        $accent = New-Object System.Windows.Forms.Panel
        $accent.Size = New-Object System.Drawing.Size(3, 282)
        $accent.BackColor = $spec.Accent
        $card.Controls.Add($accent)
        New-PanelLabel $card $spec.Title 16 14 14 $spec.Accent -Bold 264 | Out-Null
        $name = $null
        if ($spec.Subtitle) {
            $name = New-PanelLabel $card $spec.Subtitle 16 43 9 $palette.Muted 264
        }
        $cards += @{ Panel = $card; Name = $name; Accent = $spec.Accent }
    }

    $cpuTemp = New-PanelLabel $cards[0].Panel 'N/D' 16 58 36 $palette.Cyan -Bold 138
    New-PanelLabel $cards[0].Panel 'TEMPERATURA' 16 120 10 $palette.Muted 120 | Out-Null
    $cpuLoad = New-PanelLabel $cards[0].Panel '--%' 160 65 34 $palette.Text -Bold 110
    New-PanelLabel $cards[0].Panel 'CARGA' 160 121 10 $palette.Muted 110 | Out-Null
    $cpuBar = New-ProgressBar $cards[0].Panel 16 152 260 $palette.Cyan
    $cpuClock = New-PanelLabel $cards[0].Panel 'CLOCK  --' 16 176 14 $palette.Text 260

    $gpuTemp = New-PanelLabel $cards[1].Panel 'N/D' 16 58 36 $palette.Green -Bold 138
    New-PanelLabel $cards[1].Panel 'TEMPERATURA' 16 120 10 $palette.Muted 120 | Out-Null
    $gpuLoad = New-PanelLabel $cards[1].Panel '--%' 160 65 34 $palette.Text -Bold 110
    New-PanelLabel $cards[1].Panel 'CARGA' 160 121 10 $palette.Muted 110 | Out-Null
    $gpuBar = New-ProgressBar $cards[1].Panel 16 152 260 $palette.Green
    $gpuClock = New-PanelLabel $cards[1].Panel 'CLOCK  --' 16 176 13 $palette.Text 260
    $gpuMemory = New-PanelLabel $cards[1].Panel 'VRAM  --' 16 204 13 $palette.Muted 260

    $ramPercent = New-PanelLabel $cards[2].Panel '--%' 16 61 42 $palette.Orange -Bold 246
    New-PanelLabel $cards[2].Panel 'EM USO' 16 129 10 $palette.Muted 260 | Out-Null
    $ramBar = New-ProgressBar $cards[2].Panel 16 158 260 $palette.Orange
    $ramUsed = New-PanelLabel $cards[2].Panel '-- / -- GB' 16 183 19 $palette.Text -Bold 260
    New-PanelLabel $cards[2].Panel 'MEMÓRIA FÍSICA' 16 222 10 $palette.Muted 260 | Out-Null

    $fpsValue = New-PanelLabel $cards[3].Panel '--' 16 55 46 $palette.Hot -Bold 160
    New-PanelLabel $cards[3].Panel 'FPS' 20 126 10 $palette.Muted 160 | Out-Null
    $frametime = New-PanelLabel $cards[3].Panel '-- ms' 145 85 20 $palette.Text -Bold 120
    New-PanelLabel $cards[3].Panel 'FRAME TIME' 147 119 10 $palette.Muted 120 | Out-Null
    New-PanelLabel $cards[3].Panel 'DOWNLOAD' 16 169 9 $palette.Muted 260 | Out-Null
    $downloadSpeed = New-PanelLabel $cards[3].Panel '-- Mb/s' 16 183 18 $palette.Cyan -Bold 260
    New-PanelLabel $cards[3].Panel 'UPLOAD' 16 222 9 $palette.Muted 260 | Out-Null
    $uploadSpeed = New-PanelLabel $cards[3].Panel '-- Mb/s' 16 236 18 $palette.Green -Bold 260

    $chart = New-Object System.Windows.Forms.Panel
    $chart.Location = New-Object System.Drawing.Point(24, 305)
    $chart.Size = New-Object System.Drawing.Size(1232, 67)
    $chart.BackColor = [System.Drawing.Color]::Black
    $form.Controls.Add($chart)
    $chart.Add_Paint({
        param($sender, $eventArgs)
        $graphics = $eventArgs.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear($sender.BackColor)
        $validSamples = @($script:fpsHistory | Where-Object { $null -ne $_.Value })
        if ($validSamples.Count -eq 0) { return }

        $font = New-Object System.Drawing.Font('Segoe UI', 7)
        $fpsBrush = New-Object System.Drawing.SolidBrush($palette.Hot)
        $mutedBrush = New-Object System.Drawing.SolidBrush($palette.Muted)
        $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(39, 47, 59))
        $fpsPen = New-Object System.Drawing.Pen($palette.Hot, 2)
        $graphics.DrawString('FPS', $font, $mutedBrush, 10, 7)
        $left = 76
        $right = $sender.Width - 15
        $top = 17
        $bottom = $sender.Height - 24
        $now = Get-Date
        $maximumFps = 60
        if ($validSamples.Count -gt 0) {
            $maximumFps = [math]::Max(60, ($validSamples | Measure-Object -Property Value -Maximum).Maximum)
        }
        $scaleMaximum = [math]::Max(60, [math]::Ceiling(($maximumFps * 1.1) / 30) * 30)
        $graphics.DrawLine($gridPen, $left, $bottom, $right, $bottom)
        $middle = ($top + $bottom) / 2
        $graphics.DrawLine($gridPen, $left, $middle, $right, $middle)
        $graphics.DrawLine($gridPen, $left, $top, $right, $top)
        foreach ($tick in @(
            @{ Value = [string]$scaleMaximum; Y = $top - 4 },
            @{ Value = [string][int]($scaleMaximum / 2); Y = $middle - 4 },
            @{ Value = '0'; Y = $bottom - 4 }
        )) {
            $tickSize = $graphics.MeasureString($tick.Value, $font)
            $graphics.DrawString($tick.Value, $font, $mutedBrush, $left - 7 - $tickSize.Width, $tick.Y)
        }
        $graphics.DrawString('30 s', $font, $mutedBrush, $left, $sender.Height - 13)
        $nowLabel = 'agora'
        $nowSize = $graphics.MeasureString($nowLabel, $font)
        $graphics.DrawString($nowLabel, $font, $mutedBrush, $right - $nowSize.Width, $sender.Height - 13)
        for ($i = 1; $i -lt $script:fpsHistory.Count; $i++) {
            $previous = $script:fpsHistory[$i - 1]
            $current = $script:fpsHistory[$i]
            if ($null -eq $previous.Value -or $null -eq $current.Value) { continue }
            $previousX = $left + (($previous.Time - $now.AddSeconds(-$script:fpsHistorySeconds)).TotalSeconds / $script:fpsHistorySeconds) * ($right - $left)
            $currentX = $left + (($current.Time - $now.AddSeconds(-$script:fpsHistorySeconds)).TotalSeconds / $script:fpsHistorySeconds) * ($right - $left)
            $previousY = $bottom - ([math]::Min($scaleMaximum, $previous.Value) / $scaleMaximum * ($bottom - $top))
            $currentY = $bottom - ([math]::Min($scaleMaximum, $current.Value) / $scaleMaximum * ($bottom - $top))
            $graphics.DrawLine($fpsPen, [single]$previousX, [single]$previousY, [single]$currentX, [single]$currentY)
        }
        $font.Dispose(); $fpsBrush.Dispose(); $mutedBrush.Dispose()
        $gridPen.Dispose(); $fpsPen.Dispose()
    })

    $statusLabel = New-PanelLabel $form 'INICIANDO' 25 376 9 $palette.Muted 1040
    $hintLabel = New-PanelLabel $form 'ESC  |  FECHAR' 1080 376 9 $palette.Muted 176
    $hintLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $update = {
        try {
            $stats = Get-PanelStats
            $network = Get-NetworkRates

            $cpuTemp.Text = if ($null -ne $stats.CpuTemp) { "$($stats.CpuTemp)$script:degC" } else { 'N/D' }
            $cpuTemp.ForeColor = if ($null -ne $stats.CpuTemp -and $stats.CpuTemp -ge 72) { $palette.Hot } else { $palette.Cyan }
            $cpuLoad.Text = if ($null -ne $stats.CpuLoad) { "$($stats.CpuLoad)%" } else { '--%' }
            $cpuClock.Text = if ($stats.CpuClock) { 'CLOCK  {0:N2} GHz' -f ($stats.CpuClock / 1000) } else { 'CLOCK  --' }
            Set-Progress $cpuBar $stats.CpuLoad

            $gpuTemp.Text = if ($null -ne $stats.GpuTemp) { "$($stats.GpuTemp)$script:degC" } else { 'N/D' }
            $gpuTemp.ForeColor = if ($null -ne $stats.GpuTemp -and $stats.GpuTemp -ge 72) { $palette.Hot } else { $palette.Green }
            $gpuLoad.Text = if ($null -ne $stats.GpuLoad) { "$($stats.GpuLoad)%" } else { '--%' }
            $gpuClock.Text = if ($stats.GpuClock) { 'CLOCK  {0:N2} GHz' -f ($stats.GpuClock / 1000) } else { 'CLOCK  --' }
            $gpuMemory.Text = if ($null -ne $stats.GpuVram) { 'VRAM  {0:N2} GB' -f ($stats.GpuVram / 1024) } else { 'VRAM  --' }
            Set-Progress $gpuBar $stats.GpuLoad

            $ramPercent.Text = if ($null -ne $stats.RamPercent) { "$($stats.RamPercent)%" } else { '--%' }
            $ramUsed.Text = if ($null -ne $stats.RamUsed) {
                '{0:N1} / {1:N1} GB' -f $stats.RamUsed, $stats.RamTotal
            } else { '-- / -- GB' }
            Set-Progress $ramBar $stats.RamPercent

            $fpsValue.Text = if ($null -ne $stats.Fps -and $stats.Fps -gt 0) { [string]$stats.Fps } else { '--' }
            $frametime.Text = if ($null -ne $stats.Frametime) { "$($stats.Frametime) ms" } else { '-- ms' }
            $downloadSpeed.Text = if ($null -ne $network.DownloadMbps) {
                '{0:N2} Mb/s' -f $network.DownloadMbps
            } else { 'N/D' }
            $uploadSpeed.Text = if ($null -ne $network.UploadMbps) {
                '{0:N2} Mb/s' -f $network.UploadMbps
            } else { 'N/D' }

            $sampleTime = Get-Date
            $sampleFps = if ($null -ne $stats.Fps -and $stats.Fps -gt 0) { [double]$stats.Fps } else { $null }
            $script:fpsHistory.Add([pscustomobject]@{ Time = $sampleTime; Value = $sampleFps })
            $cutoff = $sampleTime.AddSeconds(-$script:fpsHistorySeconds)
            while ($script:fpsHistory.Count -gt 0 -and $script:fpsHistory[0].Time -lt $cutoff) {
                $script:fpsHistory.RemoveAt(0)
            }
            $chart.Invalidate()

            $statusLabel.Text = '{0}  |  {1}  |  MONITOR SECUNDÁRIO 1280 x 400' -f
                (Get-Date -Format 'HH:mm:ss'), $stats.Source
            $statusLabel.ForeColor = if ($stats.Source -match 'MSI Afterburner|HWiNFO') { $palette.Green } else { $palette.Muted }
            $warnings = @()
            if ($network.Error) {
                $warnings += $network.Error
            }
            if ($stats.SensorStatus) {
                $warnings += $stats.SensorStatus
            }
            if ($warnings.Count -gt 0) {
                $statusLabel.Text = '{0}  |  {1}' -f (Get-Date -Format 'HH:mm:ss'), ($warnings -join '  |  ')
                $statusLabel.ForeColor = $palette.Orange
            }
        } catch {
            $statusLabel.Text = 'ERRO NA LEITURA: ' + $_.Exception.Message
            $statusLabel.ForeColor = $palette.Red
        }
    }

    $timer.Add_Tick($update)
    $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
    $form.Add_Shown({
        if ($form.Bounds -ne $targetScreen.Bounds) {
            $form.Bounds = $targetScreen.Bounds
        }
        & $update
        $timer.Start()
    })
    [System.Windows.Forms.Application]::Run($form)
} catch {
    Write-PanelLog ('Falha ao iniciar painel: ' + $_.Exception.Message)
    exit 1
}

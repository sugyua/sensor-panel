using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Linq;
using System.Management;
using System.Net.NetworkInformation;
using System.Text;
using System.Windows.Forms;

namespace SensorPanel
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SensorPanelForm());
        }
    }

    internal sealed class DoubleBufferedPanel : Panel
    {
        public DoubleBufferedPanel()
        {
            DoubleBuffered = true;
            ResizeRedraw = true;
        }
    }

    internal sealed class FpsSample
    {
        public DateTime Time { get; set; }
        public double? Value { get; set; }
    }

    internal sealed class HardwareStats
    {
        public string CpuName { get; set; } = "Processador (Detectando...)";
        public double? CpuTemp { get; set; }
        public double? CpuLoad { get; set; }
        public double? CpuClockMhz { get; set; }

        public string GpuName { get; set; } = "Placa de Vídeo (Detectando...)";
        public double? GpuTemp { get; set; }
        public double? GpuLoad { get; set; }
        public double? GpuClockMhz { get; set; }
        public double? GpuVramMb { get; set; }

        public double? RamUsedGb { get; set; }
        public double? RamTotalGb { get; set; }
        public double? RamPercent { get; set; }

        public double? Fps { get; set; }
        public double? FrametimeMs { get; set; }

        public double? DownloadMbps { get; set; }
        public double? UploadMbps { get; set; }

        public string Source { get; set; } = "WMI (Windows)";
        public string StatusHint { get; set; } = "";
    }

    internal static class HWiNFOReader
    {
        private const string SharedMemoryName = "Global\\HWiNFO_SENS_SM2";
        private const string LocalSharedMemoryName = "HWiNFO_SENS_SM2";

        public sealed class Reading
        {
            public string Label;
            public string Unit;
            public double Value;
            public uint SensorIndex;
            public uint Type;
        }

        public sealed class Sensor
        {
            public string Name;
        }

        private static MemoryMappedFile TryOpenMap()
        {
            try
            {
                return MemoryMappedFile.OpenExisting(SharedMemoryName, MemoryMappedFileRights.Read);
            }
            catch
            {
                try
                {
                    return MemoryMappedFile.OpenExisting(LocalSharedMemoryName, MemoryMappedFileRights.Read);
                }
                catch
                {
                    return null;
                }
            }
        }

        public static bool IsAvailable()
        {
            try
            {
                using (var mmf = TryOpenMap())
                {
                    return mmf != null;
                }
            }
            catch
            {
                return false;
            }
        }

        public static List<Reading> Read(out List<Sensor> sensors)
        {
            sensors = new List<Sensor>();
            var readings = new List<Reading>();
            try
            {
                using (var map = TryOpenMap())
                {
                    if (map == null) return readings;
                    using (var view = map.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read))
                    {
                        if (view.Capacity < 44 || view.ReadUInt32(0) != 0x53695748)
                            return readings;

                        uint sensorOffset = view.ReadUInt32(20);
                        uint sensorSize = view.ReadUInt32(24);
                        uint sensorCount = view.ReadUInt32(28);
                        uint readingOffset = view.ReadUInt32(32);
                        uint readingSize = view.ReadUInt32(36);
                        uint readingCount = view.ReadUInt32(40);

                        if (sensorCount > 1024 || readingCount > 8192 || sensorSize < 136 || readingSize < 292)
                            return readings;

                        byte[] text = new byte[128];
                        byte[] unit = new byte[16];

                        for (uint i = 0; i < sensorCount; i++)
                        {
                            long address = sensorOffset + (long)i * sensorSize;
                            if (address + 136 > view.Capacity) break;
                            view.ReadArray(address + 8, text, 0, text.Length);
                            sensors.Add(new Sensor
                            {
                                Name = Encoding.UTF8.GetString(text).TrimEnd('\0').Trim()
                            });
                        }

                        for (uint i = 0; i < readingCount; i++)
                        {
                            long address = readingOffset + (long)i * readingSize;
                            if (address + 292 > view.Capacity) break;
                            var item = new Reading
                            {
                                Type = view.ReadUInt32(address),
                                SensorIndex = view.ReadUInt32(address + 4)
                            };
                            view.ReadArray(address + 12, text, 0, text.Length);
                            item.Label = Encoding.UTF8.GetString(text).TrimEnd('\0').Trim();
                            view.ReadArray(address + 268, unit, 0, unit.Length);
                            item.Unit = Encoding.UTF8.GetString(unit).TrimEnd('\0').Trim();
                            item.Value = view.ReadDouble(address + 284);
                            readings.Add(item);
                        }
                    }
                }
            }
            catch
            {
                // Ignora falhas de leitura da memória compartilhada para não interromper o app
            }
            return readings;
        }
    }

    internal static class AfterburnerReader
    {
        private const string SharedMemoryName = "MAHMSharedMemory";
        private const uint Signature = 0x4D41484D;
        private const uint MinVersion = 0x00020000;
        private const uint MaxEntries = 4096;
        private const uint MaxGpus = 64;
        private const uint ExpectedEntrySize = 1324;
        private const uint ExpectedGpuEntrySize = 1304;

        public sealed class Reading
        {
            public string Name;
            public string Unit;
            public float Value;
            public uint GpuIndex;
            public uint SourceId;
        }

        public sealed class GpuEntry
        {
            public string Id;
            public string Name;
        }

        private static string ReadAscii(MemoryMappedViewAccessor view, long offset, int length)
        {
            byte[] bytes = new byte[length];
            view.ReadArray(offset, bytes, 0, length);
            int terminator = Array.IndexOf(bytes, (byte)0);
            int count = terminator < 0 ? bytes.Length : terminator;
            return Encoding.ASCII.GetString(bytes, 0, count).Trim();
        }

        public static bool IsAvailable()
        {
            try
            {
                using (MemoryMappedFile.OpenExisting(SharedMemoryName, MemoryMappedFileRights.Read))
                {
                    return true;
                }
            }
            catch
            {
                return false;
            }
        }

        public static List<Reading> Read(out List<GpuEntry> gpus)
        {
            gpus = new List<GpuEntry>();
            var readings = new List<Reading>();
            try
            {
                using (var map = MemoryMappedFile.OpenExisting(SharedMemoryName, MemoryMappedFileRights.Read))
                using (var view = map.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read))
                {
                    if (view.Capacity < 32 || view.ReadUInt32(0) != Signature)
                        return readings;

                    uint version = view.ReadUInt32(4);
                    uint headerSize = view.ReadUInt32(8);
                    uint count = view.ReadUInt32(12);
                    uint entrySize = view.ReadUInt32(16);
                    uint gpuCount = view.ReadUInt32(24);
                    uint gpuEntrySize = view.ReadUInt32(28);

                    if (version < MinVersion || headerSize < 32 || headerSize > view.Capacity ||
                        count > MaxEntries || gpuCount > MaxGpus ||
                        (count > 0 && entrySize != ExpectedEntrySize) ||
                        (gpuCount > 0 && gpuEntrySize != ExpectedGpuEntrySize))
                    {
                        return readings;
                    }

                    long entriesOffset = headerSize;
                    long gpuOffset = entriesOffset + (long)count * entrySize;
                    long endOffset = gpuOffset + (long)gpuCount * gpuEntrySize;
                    if (endOffset > view.Capacity)
                        return readings;

                    for (uint i = 0; i < count; i++)
                    {
                        long address = entriesOffset + (long)i * entrySize;
                        float value = view.ReadSingle(address + 1300);
                        if (float.IsNaN(value) || float.IsInfinity(value) || Math.Abs(value) >= 1.0e30f)
                            continue;

                        readings.Add(new Reading
                        {
                            Name = ReadAscii(view, address, 260),
                            Unit = ReadAscii(view, address + 260, 260),
                            Value = value,
                            GpuIndex = view.ReadUInt32(address + 1316),
                            SourceId = view.ReadUInt32(address + 1320)
                        });
                    }

                    for (uint i = 0; i < gpuCount; i++)
                    {
                        long address = gpuOffset + (long)i * gpuEntrySize;
                        gpus.Add(new GpuEntry
                        {
                            Id = ReadAscii(view, address, 260),
                            Name = ReadAscii(view, address + 520, 260)
                        });
                    }
                }
            }
            catch
            {
                // Ignora falhas de leitura do MSI Afterburner
            }
            return readings;
        }
    }

    internal static class RtssReader
    {
        private const string SharedMemoryName = "Global\\RTSSSharedMemoryV2";
        private const string LocalSharedMemoryName = "RTSSSharedMemoryV2";

        private static MemoryMappedFile TryOpenMap()
        {
            try
            {
                return MemoryMappedFile.OpenExisting(SharedMemoryName, MemoryMappedFileRights.Read);
            }
            catch
            {
                try
                {
                    return MemoryMappedFile.OpenExisting(LocalSharedMemoryName, MemoryMappedFileRights.Read);
                }
                catch
                {
                    return null;
                }
            }
        }

        public static int? GetFps()
        {
            try
            {
                using (var mmf = TryOpenMap())
                {
                    if (mmf == null) return null;
                    using (var view = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read))
                    {
                        if (view.Capacity < 20 || view.ReadUInt32(0) != 0x53535452)
                            return null;

                        uint appEntrySize = view.ReadUInt32(8);
                        uint appArrOffset = view.ReadUInt32(12);
                        uint appArrSize = view.ReadUInt32(16);
                        if (appEntrySize == 0 || appArrSize == 0 || appArrSize > 512)
                            return null;

                        int[,] offsetSets = new int[,]
                        {
                            { 276, 268, 272 },
                            { 532, 524, 528 },
                            { 796, 800, 804 },
                            { 280, 284, 288 }
                        };

                        int bestFps = -1;
                        for (uint i = 0; i < appArrSize; i++)
                        {
                            long baseOffset = appArrOffset + (long)i * appEntrySize;
                            if (baseOffset + appEntrySize > view.Capacity) break;
                            uint pid = view.ReadUInt32(baseOffset);
                            if (pid == 0) continue;

                            for (int s = 0; s < offsetSets.GetLength(0); s++)
                            {
                                long oFrames = offsetSets[s, 0];
                                long oT0 = offsetSets[s, 1];
                                long oT1 = offsetSets[s, 2];
                                if (oFrames + 4 > appEntrySize || oT1 + 4 > appEntrySize) continue;

                                uint frames = view.ReadUInt32(baseOffset + oFrames);
                                uint time0 = view.ReadUInt32(baseOffset + oT0);
                                uint time1 = view.ReadUInt32(baseOffset + oT1);

                                if (frames > 0 && time1 > time0)
                                {
                                    double elapsed = (time1 - time0) / 1000.0;
                                    if (elapsed > 0.01)
                                    {
                                        int fps = (int)Math.Round(frames / elapsed);
                                        if (fps > 0 && fps < 5000 && fps > bestFps)
                                            bestFps = fps;
                                    }
                                }
                            }
                        }
                        return bestFps > 0 ? (int?)bestFps : null;
                    }
                }
            }
            catch
            {
                return null;
            }
        }
    }

    internal sealed class HardwareCollector
    {
        private string _cachedCpuName;
        private string _cachedGpuName;
        private DateTime? _prevNetSampleTime;
        private Dictionary<string, (double Rx, double Tx)> _prevNetCounters;

        public HardwareCollector()
        {
            DetectStaticHardwareNames();
        }

        private void DetectStaticHardwareNames()
        {
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT Name FROM Win32_Processor"))
                {
                    foreach (ManagementObject obj in searcher.Get())
                    {
                        var name = Convert.ToString(obj["Name"])?.Trim();
                        if (!string.IsNullOrWhiteSpace(name))
                        {
                            _cachedCpuName = name;
                            break;
                        }
                    }
                }
            }
            catch
            {
                // Fallback seguro caso o WMI demore ou falhe
            }

            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT Name, PNPDeviceID, AdapterRAM FROM Win32_VideoController"))
                {
                    string bestGpu = null;
                    foreach (ManagementObject obj in searcher.Get())
                    {
                        string name = Convert.ToString(obj["Name"])?.Trim();
                        string pnp = Convert.ToString(obj["PNPDeviceID"]) ?? "";
                        if (string.IsNullOrWhiteSpace(name)) continue;

                        string lower = name.ToLowerInvariant();
                        if (lower.Contains("parsec") || lower.Contains("virtual") ||
                            lower.Contains("remote display") || lower.Contains("microsoft basic") ||
                            lower.Contains("indirect display"))
                        {
                            continue;
                        }

                        if (pnp.StartsWith("PCI\\", StringComparison.OrdinalIgnoreCase))
                        {
                            bestGpu = name;
                            break;
                        }
                        if (bestGpu == null)
                            bestGpu = name;
                    }

                    if (!string.IsNullOrWhiteSpace(bestGpu))
                        _cachedGpuName = bestGpu;
                }
            }
            catch
            {
                // Fallback seguro
            }
        }

        public HardwareStats Collect()
        {
            var stats = new HardwareStats
            {
                CpuName = !string.IsNullOrWhiteSpace(_cachedCpuName) ? _cachedCpuName : "Processador (WMI)",
                GpuName = !string.IsNullOrWhiteSpace(_cachedGpuName) ? _cachedGpuName : "Placa de Vídeo (WMI)",
                Source = "WMI (Windows)"
            };

            // 1. Leitura básica WMI (Carga CPU, Clock CPU e Memória RAM)
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT LoadPercentage, CurrentClockSpeed, Name FROM Win32_Processor"))
                {
                    double loadSum = 0;
                    int loadCount = 0;
                    double clockMax = 0;
                    foreach (ManagementObject obj in searcher.Get())
                    {
                        if (string.IsNullOrWhiteSpace(_cachedCpuName))
                        {
                            string n = Convert.ToString(obj["Name"])?.Trim();
                            if (!string.IsNullOrWhiteSpace(n))
                            {
                                _cachedCpuName = n;
                                stats.CpuName = n;
                            }
                        }
                        if (obj["LoadPercentage"] != null)
                        {
                            loadSum += Convert.ToDouble(obj["LoadPercentage"]);
                            loadCount++;
                        }
                        if (obj["CurrentClockSpeed"] != null)
                        {
                            double clk = Convert.ToDouble(obj["CurrentClockSpeed"]);
                            if (clk > clockMax) clockMax = clk;
                        }
                    }
                    if (loadCount > 0) stats.CpuLoad = Math.Round(loadSum / loadCount);
                    if (clockMax > 0) stats.CpuClockMhz = clockMax;
                }
            }
            catch { }

            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem"))
                {
                    foreach (ManagementObject obj in searcher.Get())
                    {
                        double totalKb = Convert.ToDouble(obj["TotalVisibleMemorySize"]);
                        double freeKb = Convert.ToDouble(obj["FreePhysicalMemory"]);
                        if (totalKb > 0)
                        {
                            double usedKb = Math.Max(0, totalKb - freeKb);
                            stats.RamTotalGb = Math.Round(totalKb / (1024.0 * 1024.0), 1);
                            stats.RamUsedGb = Math.Round(usedKb / (1024.0 * 1024.0), 1);
                            stats.RamPercent = Math.Round((usedKb / totalKb) * 100.0);
                        }
                        break;
                    }
                }
            }
            catch { }

            // 2. Leitura opcional HWiNFO64 (Memória Compartilhada)
            bool hwinfoUsed = false;
            try
            {
                if (HWiNFOReader.IsAvailable())
                {
                    List<HWiNFOReader.Sensor> sensors;
                    var readings = HWiNFOReader.Read(out sensors);
                    if (readings.Count > 0)
                    {
                        hwinfoUsed = true;
                        stats.Source = "HWiNFO64 + WMI";

                        int cpuIdx = -1;
                        int gpuIdx = -1;
                        for (int i = 0; i < sensors.Count; i++)
                        {
                            string sName = sensors[i].Name ?? "";
                            string lower = sName.ToLowerInvariant();
                            if (cpuIdx < 0 && (lower.Contains("cpu") || lower.Contains("processor") || lower.Contains("ryzen") || lower.Contains("intel") || lower.Contains("core")))
                            {
                                cpuIdx = i;
                            }
                            if (gpuIdx < 0 && (lower.Contains("gpu") || lower.Contains("radeon") || lower.Contains("geforce") || lower.Contains("rtx") || lower.Contains("gtx") || lower.Contains("arc")))
                            {
                                gpuIdx = i;
                            }
                        }

                        int bestCpuTempScore = 0;
                        int bestGpuTempScore = 0;
                        double bestGpuClock = 0;

                        foreach (var r in readings)
                        {
                            string label = (r.Label ?? "").ToLowerInvariant();
                            int idx = (int)r.SensorIndex;
                            double val = r.Value;

                            // Temperaturas (Type == 1)
                            if (r.Type == 1 && val >= 5 && val < 120)
                            {
                                if ((idx == cpuIdx || label.Contains("cpu") || label.Contains("tctl") || label.Contains("tdie") || label.Contains("package")) &&
                                    !label.Contains("gpu") && !label.Contains("pch") && !label.Contains("vrm"))
                                {
                                    int score = (label.Contains("tdie") || label.Contains("tctl") || label.Contains("package")) ? 3 : 1;
                                    if (score >= bestCpuTempScore)
                                    {
                                        bestCpuTempScore = score;
                                        stats.CpuTemp = Math.Round(val);
                                    }
                                }

                                if ((idx == gpuIdx || label.Contains("gpu")) &&
                                    (label.Contains("gpu") || label.Contains("edge")) &&
                                    !label.Contains("hotspot") && !label.Contains("junction") && !label.Contains("memory") && !label.Contains("vram"))
                                {
                                    int score = (label.StartsWith("gpu temp") || label == "gpu temperature") ? 3 : 1;
                                    if (score >= bestGpuTempScore)
                                    {
                                        bestGpuTempScore = score;
                                        stats.GpuTemp = Math.Round(val);
                                    }
                                }
                            }

                            // Cargas % (Type == 7)
                            if (r.Type == 7 && val >= 0 && val <= 100)
                            {
                                if (label.Contains("total cpu") || label.Contains("cpu total") || label == "cpu usage" || label == "cpu utilization")
                                {
                                    stats.CpuLoad = Math.Round(val);
                                }
                                if (label.Contains("gpu core load") || label == "gpu usage" || label == "gpu utilization" || label == "gpu load" || label.Contains("d3d 3d"))
                                {
                                    stats.GpuLoad = Math.Round(val);
                                }
                                if (label.Contains("physical memory load") || label == "memory usage" || label == "ram usage")
                                {
                                    stats.RamPercent = Math.Round(val);
                                }
                            }

                            // Clocks MHz (Type == 6)
                            if (r.Type == 6 && val > 50)
                            {
                                if ((idx == gpuIdx || label.Contains("gpu")) &&
                                    !label.Contains("memory") && !label.Contains("video") && !label.Contains("display") && !label.Contains("pcie"))
                                {
                                    if (val > bestGpuClock) bestGpuClock = val;
                                }
                            }

                            // VRAM
                            if (val > 10 && val < 100000 &&
                                (label.Contains("d3d memory dedicated") || label.Contains("gpu memory allocated") ||
                                 label.Contains("gpu memory used") || label.Contains("vram used") || label.Contains("fb memory used")))
                            {
                                stats.GpuVramMb = (r.Unit != null && r.Unit.IndexOf("GB", StringComparison.OrdinalIgnoreCase) >= 0)
                                    ? Math.Round(val * 1024.0)
                                    : Math.Round(val);
                            }

                            // FPS via HWiNFO
                            if (!stats.Fps.HasValue && val > 0 && val < 5000 &&
                                (label.Contains("frame rate") || label.Contains("framerate") || label == "fps" || label.Contains("frames per")))
                            {
                                stats.Fps = Math.Round(val);
                            }
                        }

                        if (bestGpuClock > 0)
                            stats.GpuClockMhz = bestGpuClock;
                    }
                }
            }
            catch { }

            // 3. Leitura opcional MSI Afterburner (MAHMSharedMemory)
            bool afterburnerUsed = false;
            try
            {
                if (AfterburnerReader.IsAvailable())
                {
                    List<AfterburnerReader.GpuEntry> gpus;
                    var readings = AfterburnerReader.Read(out gpus);
                    if (readings.Count > 0)
                    {
                        afterburnerUsed = true;
                        stats.Source = hwinfoUsed ? "MSI Afterburner + HWiNFO64" : "MSI Afterburner";

                        int gpuIndex = 0;
                        if (gpus.Count > 0 && !string.IsNullOrWhiteSpace(gpus[0].Name))
                        {
                            stats.GpuName = gpus[0].Name;
                        }

                        var globalReadings = readings.Where(r => r.GpuIndex == uint.MaxValue).ToList();
                        var gpuReadings = readings.Where(r => r.GpuIndex == (uint)gpuIndex).ToList();

                        var cpuTemp = globalReadings.FirstOrDefault(r => r.SourceId == 0x80);
                        var cpuLoad = globalReadings.FirstOrDefault(r => r.SourceId == 0x90);
                        var cpuClock = globalReadings.FirstOrDefault(r => r.SourceId == 0xA0);
                        var gpuTemp = gpuReadings.FirstOrDefault(r => r.SourceId == 0x00);
                        var gpuLoad = gpuReadings.FirstOrDefault(r => r.SourceId == 0x30);
                        var gpuMem = gpuReadings.FirstOrDefault(r => r.SourceId == 0x31);
                        var gpuClock = gpuReadings.FirstOrDefault(r => r.SourceId == 0x20);
                        var ramUsed = readings.FirstOrDefault(r => r.SourceId == 0x91);
                        var fps = globalReadings.FirstOrDefault(r => r.SourceId == 0x50);
                        var frametime = readings.FirstOrDefault(r => r.SourceId == 0x51 && r.Value > 0 && r.Value < 10000);

                        if (cpuTemp != null && cpuTemp.Value >= 0 && cpuTemp.Value < 150)
                            stats.CpuTemp = Math.Round(cpuTemp.Value);
                        if (cpuLoad != null && cpuLoad.Value >= 0 && cpuLoad.Value <= 100)
                            stats.CpuLoad = Math.Round(cpuLoad.Value);
                        if (cpuClock != null && cpuClock.Value > 0)
                            stats.CpuClockMhz = cpuClock.Value;

                        if (gpuTemp != null && gpuTemp.Value >= 0 && gpuTemp.Value < 150)
                            stats.GpuTemp = Math.Round(gpuTemp.Value);
                        if (gpuLoad != null && gpuLoad.Value >= 0 && gpuLoad.Value <= 100)
                            stats.GpuLoad = Math.Round(gpuLoad.Value);
                        if (gpuClock != null && gpuClock.Value > 0)
                            stats.GpuClockMhz = gpuClock.Value;
                        if (gpuMem != null && gpuMem.Value >= 0)
                            stats.GpuVramMb = Math.Round(gpuMem.Value);

                        if (ramUsed != null && ramUsed.Value >= 0 && ramUsed.Unit != null && ramUsed.Unit.IndexOf("MB", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            stats.RamUsedGb = Math.Round(ramUsed.Value / 1024.0, 1);
                            if (stats.RamTotalGb.HasValue && stats.RamTotalGb.Value > 0)
                                stats.RamPercent = Math.Round((stats.RamUsedGb.Value / stats.RamTotalGb.Value) * 100.0);
                        }

                        if (fps != null && fps.Value > 0 && fps.Value < 5000)
                            stats.Fps = Math.Round(fps.Value);
                        if (frametime != null && frametime.Value > 0 && frametime.Value < 10000)
                            stats.FrametimeMs = Math.Round(frametime.Value, 1);
                    }
                }
            }
            catch { }

            // 4. Fallback RTSS direto para FPS se Afterburner não forneceu
            if (!stats.Fps.HasValue)
            {
                int? rtssFps = RtssReader.GetFps();
                if (rtssFps.HasValue && rtssFps.Value > 0)
                {
                    stats.Fps = rtssFps.Value;
                }
            }

            if (stats.Fps.HasValue && stats.Fps.Value > 0 && !stats.FrametimeMs.HasValue)
            {
                stats.FrametimeMs = Math.Round(1000.0 / stats.Fps.Value, 1);
            }

            // 5. Fallback temperatura WMI caso nem Afterburner nem HWiNFO estejam ativos
            if (!stats.CpuTemp.HasValue)
            {
                try
                {
                    using (var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature"))
                    {
                        double maxKelvin10 = 0;
                        foreach (ManagementObject obj in searcher.Get())
                        {
                            double t = Convert.ToDouble(obj["CurrentTemperature"]);
                            if (t >= 2732 && t <= 3932 && t > maxKelvin10)
                                maxKelvin10 = t;
                        }
                        if (maxKelvin10 > 0)
                            stats.CpuTemp = Math.Round((maxKelvin10 / 10.0) - 273.15);
                    }
                }
                catch { }
            }

            if (!hwinfoUsed && !afterburnerUsed)
            {
                stats.StatusHint = "Dica: abra o MSI Afterburner ou HWiNFO64 (Shared Memory) para ler temperaturas da GPU/CPU e FPS.";
            }

            // 6. Taxas de Rede (Download / Upload em Mb/s)
            CollectNetworkRates(stats);

            return stats;
        }

        private void CollectNetworkRates(HardwareStats stats)
        {
            try
            {
                var interfaces = NetworkInterface.GetAllNetworkInterfaces()
                    .Where(ni => ni.OperationalStatus == OperationalStatus.Up &&
                                 ni.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                                 ni.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                    .ToList();

                var current = new Dictionary<string, (double Rx, double Tx)>();
                foreach (var ni in interfaces)
                {
                    try
                    {
                        var ipStats = ni.GetIPStatistics();
                        current[ni.Id] = (ipStats.BytesReceived, ipStats.BytesSent);
                    }
                    catch { }
                }

                DateTime now = DateTime.UtcNow;
                if (_prevNetSampleTime.HasValue && _prevNetCounters != null && current.Count > 0)
                {
                    double elapsed = (now - _prevNetSampleTime.Value).TotalSeconds;
                    if (elapsed > 0.05)
                    {
                        double rxDelta = 0;
                        double txDelta = 0;
                        bool anyMatch = false;

                        foreach (var kvp in current)
                        {
                            if (_prevNetCounters.TryGetValue(kvp.Key, out var prev))
                            {
                                double dRx = kvp.Value.Rx - prev.Rx;
                                double dTx = kvp.Value.Tx - prev.Tx;
                                if (dRx >= 0 && dTx >= 0)
                                {
                                    rxDelta += dRx;
                                    txDelta += dTx;
                                    anyMatch = true;
                                }
                            }
                        }

                        if (anyMatch)
                        {
                            stats.DownloadMbps = (rxDelta * 8.0) / (elapsed * 1_000_000.0);
                            stats.UploadMbps = (txDelta * 8.0) / (elapsed * 1_000_000.0);
                        }
                    }
                }

                _prevNetSampleTime = now;
                _prevNetCounters = current;
            }
            catch
            {
                stats.DownloadMbps = null;
                stats.UploadMbps = null;
            }
        }
    }

    internal sealed class SensorPanelForm : Form
    {
        private readonly HardwareCollector _collector = new HardwareCollector();
        private readonly List<FpsSample> _fpsHistory = new List<FpsSample>();
        private const int FpsHistorySeconds = 30;
        private readonly Timer _timer;

        private readonly Color _bgDark = Color.FromArgb(10, 12, 18);
        private readonly Color _cardBg = Color.FromArgb(18, 22, 32);
        private readonly Color _trackBg = Color.FromArgb(34, 41, 56);
        private readonly Color _textPrimary = Color.FromArgb(235, 240, 248);
        private readonly Color _textMuted = Color.FromArgb(128, 142, 162);
        private readonly Color _cyan = Color.FromArgb(40, 208, 220);
        private readonly Color _green = Color.FromArgb(104, 222, 157);
        private readonly Color _orange = Color.FromArgb(255, 181, 82);
        private readonly Color _hotRed = Color.FromArgb(255, 72, 82);

        // Controles dinâmicos CPU
        private Label _lblCpuTitle;
        private Label _lblCpuTemp;
        private Label _lblCpuLoad;
        private Label _lblCpuClock;
        private Panel _barCpuTrack;
        private Panel _barCpuFill;

        // Controles dinâmicos GPU
        private Label _lblGpuTitle;
        private Label _lblGpuTemp;
        private Label _lblGpuLoad;
        private Label _lblGpuClock;
        private Label _lblGpuVram;
        private Panel _barGpuTrack;
        private Panel _barGpuFill;

        // Controles dinâmicos RAM
        private Label _lblRamPercent;
        private Label _lblRamUsed;
        private Panel _barRamTrack;
        private Panel _barRamFill;

        // Controles dinâmicos Desempenho / Rede
        private Label _lblFpsValue;
        private Label _lblFrametime;
        private Label _lblDownload;
        private Label _lblUpload;

        // Gráfico e Rodapé
        private DoubleBufferedPanel _chartPanel;
        private Label _lblStatus;

        public SensorPanelForm()
        {
            Text = "Sensor Panel — Monitor de Hardware e Desempenho";
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            BackColor = _bgDark;
            ForeColor = _textPrimary;
            MinimumSize = new Size(880, 360);
            KeyPreview = true;

            ConfigureWindowPlacement();
            BuildResponsiveLayout();

            KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Escape)
                    Close();
            };

            _timer = new Timer { Interval = 1000 };
            _timer.Tick += (s, e) => UpdateMetrics();

            Shown += (s, e) =>
            {
                UpdateMetrics();
                _timer.Start();
            };

            FormClosed += (s, e) =>
            {
                _timer.Stop();
                _timer.Dispose();
            };
        }

        private void ConfigureWindowPlacement()
        {
            Screen[] screens = Screen.AllScreens;
            Screen dedicated1280x400 = screens.FirstOrDefault(s => !s.Primary && s.Bounds.Width == 1280 && s.Bounds.Height == 400);
            Screen anySecondary = screens.FirstOrDefault(s => !s.Primary);

            if (dedicated1280x400 != null)
            {
                FormBorderStyle = FormBorderStyle.None;
                StartPosition = FormStartPosition.Manual;
                Bounds = dedicated1280x400.Bounds;
                TopMost = true;
                ShowInTaskbar = false;
            }
            else if (anySecondary != null)
            {
                FormBorderStyle = FormBorderStyle.Sizable;
                StartPosition = FormStartPosition.Manual;
                int w = Math.Min(1280, Math.Max(900, (int)(anySecondary.WorkingArea.Width * 0.85)));
                int h = Math.Min(460, Math.Max(380, (int)(anySecondary.WorkingArea.Height * 0.45)));
                int x = anySecondary.WorkingArea.Left + (anySecondary.WorkingArea.Width - w) / 2;
                int y = anySecondary.WorkingArea.Top + (anySecondary.WorkingArea.Height - h) / 2;
                Bounds = new Rectangle(x, y, w, h);
                ShowInTaskbar = true;
            }
            else
            {
                FormBorderStyle = FormBorderStyle.Sizable;
                StartPosition = FormStartPosition.CenterScreen;
                ClientSize = new Size(1240, 430);
                ShowInTaskbar = true;
            }
        }

        private void BuildResponsiveLayout()
        {
            var rootGrid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 3,
                Padding = new Padding(12),
                BackColor = _bgDark
            };
            rootGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            rootGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 72F));
            rootGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 28F));
            rootGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 28F));
            Controls.Add(rootGrid);

            // Grade superior com 4 cartões responsivos
            var cardsGrid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 4,
                RowCount = 1,
                Margin = new Padding(0, 0, 0, 8)
            };
            for (int i = 0; i < 4; i++)
                cardsGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            cardsGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            rootGrid.Controls.Add(cardsGrid, 0, 0);

            cardsGrid.Controls.Add(BuildCpuCard(), 0, 0);
            cardsGrid.Controls.Add(BuildGpuCard(), 1, 0);
            cardsGrid.Controls.Add(BuildRamCard(), 2, 0);
            cardsGrid.Controls.Add(BuildPerfCard(), 3, 0);

            // Painel do gráfico de FPS (responsivo)
            _chartPanel = new DoubleBufferedPanel
            {
                Dock = DockStyle.Fill,
                BackColor = _cardBg,
                Margin = new Padding(4, 0, 4, 6)
            };
            _chartPanel.Paint += ChartPanel_Paint;
            rootGrid.Controls.Add(_chartPanel, 0, 1);

            // Barra de status inferior
            var footerGrid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 1,
                Margin = new Padding(4, 0, 4, 0)
            };
            footerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 80F));
            footerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20F));

            _lblStatus = new Label
            {
                Dock = DockStyle.Fill,
                Text = "Iniciando leitura de sensores...",
                Font = new Font("Segoe UI", 8.5F, FontStyle.Regular),
                ForeColor = _textMuted,
                TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true
            };

            var lblHint = new Label
            {
                Dock = DockStyle.Fill,
                Text = "ESC ou X  |  FECHAR",
                Font = new Font("Segoe UI", 8.5F, FontStyle.Regular),
                ForeColor = _textMuted,
                TextAlign = ContentAlignment.MiddleRight
            };

            footerGrid.Controls.Add(_lblStatus, 0, 0);
            footerGrid.Controls.Add(lblHint, 1, 0);
            rootGrid.Controls.Add(footerGrid, 0, 2);
        }

        private Panel CreateCardContainer(Color accentColor, out TableLayoutPanel contentGrid, out Label titleLabel, string initialTitle)
        {
            var outer = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = _cardBg,
                Margin = new Padding(4, 0, 4, 0)
            };

            var accent = new Panel
            {
                Dock = DockStyle.Left,
                Width = 4,
                BackColor = accentColor
            };

            contentGrid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                Padding = new Padding(12, 10, 12, 10),
                ColumnCount = 2,
                RowCount = 5
            };
            contentGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 52F));
            contentGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 48F));
            contentGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 32F)); // Título
            contentGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 48F));  // Métricas principais
            contentGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 20F)); // Legendas métricas
            contentGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 16F)); // Barra progresso
            contentGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 52F));  // Detalhes inferiores

            titleLabel = new Label
            {
                Dock = DockStyle.Fill,
                Text = initialTitle,
                Font = new Font("Segoe UI", 11.5F, FontStyle.Bold),
                ForeColor = accentColor,
                TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true
            };
            contentGrid.Controls.Add(titleLabel, 0, 0);
            contentGrid.SetColumnSpan(titleLabel, 2);

            outer.Controls.Add(contentGrid);
            outer.Controls.Add(accent);
            return outer;
        }

        private void CreateProgressTrack(TableLayoutPanel grid, int row, Color fillColor, out Panel track, out Panel fill)
        {
            var host = new Panel
            {
                Dock = DockStyle.Fill,
                Padding = new Padding(0, 4, 0, 4)
            };
            var trackPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 6,
                BackColor = _trackBg
            };
            var fillPanel = new Panel
            {
                Location = new Point(0, 0),
                Size = new Size(0, 6),
                BackColor = fillColor
            };
            trackPanel.Controls.Add(fillPanel);
            host.Controls.Add(trackPanel);
            grid.Controls.Add(host, 0, row);
            grid.SetColumnSpan(host, 2);

            track = trackPanel;
            fill = fillPanel;
        }

        private Panel BuildCpuCard()
        {
            var card = CreateCardContainer(_cyan, out var grid, out _lblCpuTitle, "Processador");

            _lblCpuTemp = CreateBigValueLabel("N/A", _cyan);
            _lblCpuLoad = CreateBigValueLabel("N/A", _textPrimary);
            grid.Controls.Add(_lblCpuTemp, 0, 1);
            grid.Controls.Add(_lblCpuLoad, 1, 1);

            grid.Controls.Add(CreateCaptionLabel("TEMPERATURA"), 0, 2);
            grid.Controls.Add(CreateCaptionLabel("CARGA"), 1, 2);

            CreateProgressTrack(grid, 3, _cyan, out _barCpuTrack, out _barCpuFill);

            _lblCpuClock = new Label
            {
                Dock = DockStyle.Fill,
                Text = "CLOCK: N/A",
                Font = new Font("Segoe UI", 11F, FontStyle.Regular),
                ForeColor = _textPrimary,
                TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true
            };
            grid.Controls.Add(_lblCpuClock, 0, 4);
            grid.SetColumnSpan(_lblCpuClock, 2);

            return card;
        }

        private Panel BuildGpuCard()
        {
            var card = CreateCardContainer(_green, out var grid, out _lblGpuTitle, "Placa de Vídeo");

            _lblGpuTemp = CreateBigValueLabel("N/A", _green);
            _lblGpuLoad = CreateBigValueLabel("N/A", _textPrimary);
            grid.Controls.Add(_lblGpuTemp, 0, 1);
            grid.Controls.Add(_lblGpuLoad, 1, 1);

            grid.Controls.Add(CreateCaptionLabel("TEMPERATURA"), 0, 2);
            grid.Controls.Add(CreateCaptionLabel("CARGA"), 1, 2);

            CreateProgressTrack(grid, 3, _green, out _barGpuTrack, out _barGpuFill);

            var bottomDetails = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 2
            };
            bottomDetails.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            bottomDetails.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            bottomDetails.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));

            _lblGpuClock = new Label
            {
                Dock = DockStyle.Fill,
                Text = "CLOCK: N/A",
                Font = new Font("Segoe UI", 10.5F, FontStyle.Regular),
                ForeColor = _textPrimary,
                TextAlign = ContentAlignment.MiddleLeft
            };
            _lblGpuVram = new Label
            {
                Dock = DockStyle.Fill,
                Text = "VRAM: N/A",
                Font = new Font("Segoe UI", 10.5F, FontStyle.Regular),
                ForeColor = _textMuted,
                TextAlign = ContentAlignment.MiddleLeft
            };
            bottomDetails.Controls.Add(_lblGpuClock, 0, 0);
            bottomDetails.Controls.Add(_lblGpuVram, 0, 1);

            grid.Controls.Add(bottomDetails, 0, 4);
            grid.SetColumnSpan(bottomDetails, 2);

            return card;
        }

        private Panel BuildRamCard()
        {
            var card = CreateCardContainer(_orange, out var grid, out _, "Memória RAM");

            _lblRamPercent = CreateBigValueLabel("N/A", _orange);
            grid.Controls.Add(_lblRamPercent, 0, 1);
            grid.SetColumnSpan(_lblRamPercent, 2);

            var cap = CreateCaptionLabel("EM USO (%)");
            grid.Controls.Add(cap, 0, 2);
            grid.SetColumnSpan(cap, 2);

            CreateProgressTrack(grid, 3, _orange, out _barRamTrack, out _barRamFill);

            _lblRamUsed = new Label
            {
                Dock = DockStyle.Fill,
                Text = "FÍSICA: N/A",
                Font = new Font("Segoe UI", 12F, FontStyle.Bold),
                ForeColor = _textPrimary,
                TextAlign = ContentAlignment.MiddleLeft
            };
            grid.Controls.Add(_lblRamUsed, 0, 4);
            grid.SetColumnSpan(_lblRamUsed, 2);

            return card;
        }

        private Panel BuildPerfCard()
        {
            var card = CreateCardContainer(_hotRed, out var grid, out _, "Desempenho & Rede");

            _lblFpsValue = CreateBigValueLabel("N/A", _hotRed);
            _lblFrametime = new Label
            {
                Dock = DockStyle.Fill,
                Text = "N/A",
                Font = new Font("Segoe UI", 15F, FontStyle.Bold),
                ForeColor = _textPrimary,
                TextAlign = ContentAlignment.BottomLeft
            };
            grid.Controls.Add(_lblFpsValue, 0, 1);
            grid.Controls.Add(_lblFrametime, 1, 1);

            grid.Controls.Add(CreateCaptionLabel("FPS (RTSS/AB)"), 0, 2);
            grid.Controls.Add(CreateCaptionLabel("FRAME TIME"), 1, 2);

            var netGrid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 2
            };
            netGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            netGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            netGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 16F));
            netGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            netGrid.Controls.Add(CreateCaptionLabel("DOWNLOAD"), 0, 0);
            netGrid.Controls.Add(CreateCaptionLabel("UPLOAD"), 1, 0);

            _lblDownload = new Label
            {
                Dock = DockStyle.Fill,
                Text = "N/A",
                Font = new Font("Segoe UI", 11F, FontStyle.Bold),
                ForeColor = _cyan,
                TextAlign = ContentAlignment.MiddleLeft
            };
            _lblUpload = new Label
            {
                Dock = DockStyle.Fill,
                Text = "N/A",
                Font = new Font("Segoe UI", 11F, FontStyle.Bold),
                ForeColor = _green,
                TextAlign = ContentAlignment.MiddleLeft
            };
            netGrid.Controls.Add(_lblDownload, 0, 1);
            netGrid.Controls.Add(_lblUpload, 1, 1);

            grid.Controls.Add(netGrid, 0, 4);
            grid.SetColumnSpan(netGrid, 2);

            return card;
        }

        private Label CreateBigValueLabel(string text, Color color)
        {
            return new Label
            {
                Dock = DockStyle.Fill,
                Text = text,
                Font = new Font("Segoe UI", 22F, FontStyle.Bold),
                ForeColor = color,
                TextAlign = ContentAlignment.BottomLeft,
                AutoEllipsis = true
            };
        }

        private Label CreateCaptionLabel(string text)
        {
            return new Label
            {
                Dock = DockStyle.Fill,
                Text = text,
                Font = new Font("Segoe UI", 8F, FontStyle.Regular),
                ForeColor = _textMuted,
                TextAlign = ContentAlignment.TopLeft
            };
        }

        private static void UpdateProgressFill(Panel track, Panel fill, double? percent)
        {
            if (track == null || fill == null) return;
            if (!percent.HasValue)
            {
                fill.Width = 0;
                return;
            }
            double clamped = Math.Max(0.0, Math.Min(100.0, percent.Value));
            fill.Width = (int)Math.Round(track.ClientSize.Width * (clamped / 100.0));
        }

        private void UpdateMetrics()
        {
            try
            {
                var st = _collector.Collect();

                // CPU
                _lblCpuTitle.Text = st.CpuName;
                _lblCpuTemp.Text = st.CpuTemp.HasValue ? $"{st.CpuTemp.Value:0}°C" : "N/A";
                _lblCpuTemp.ForeColor = (st.CpuTemp.HasValue && st.CpuTemp.Value >= 72) ? _hotRed : _cyan;
                _lblCpuLoad.Text = st.CpuLoad.HasValue ? $"{st.CpuLoad.Value:0}%" : "N/A";
                _lblCpuClock.Text = st.CpuClockMhz.HasValue
                    ? $"CLOCK: {st.CpuClockMhz.Value / 1000.0:N2} GHz"
                    : "CLOCK: N/A";
                UpdateProgressFill(_barCpuTrack, _barCpuFill, st.CpuLoad);

                // GPU
                _lblGpuTitle.Text = st.GpuName;
                _lblGpuTemp.Text = st.GpuTemp.HasValue ? $"{st.GpuTemp.Value:0}°C" : "N/A";
                _lblGpuTemp.ForeColor = (st.GpuTemp.HasValue && st.GpuTemp.Value >= 72) ? _hotRed : _green;
                _lblGpuLoad.Text = st.GpuLoad.HasValue ? $"{st.GpuLoad.Value:0}%" : "N/A";
                _lblGpuClock.Text = st.GpuClockMhz.HasValue
                    ? $"CLOCK: {st.GpuClockMhz.Value / 1000.0:N2} GHz"
                    : "CLOCK: N/A";
                _lblGpuVram.Text = st.GpuVramMb.HasValue
                    ? $"VRAM: {st.GpuVramMb.Value / 1024.0:N2} GB ({st.GpuVramMb.Value:0} MB)"
                    : "VRAM: N/A";
                UpdateProgressFill(_barGpuTrack, _barGpuFill, st.GpuLoad);

                // RAM
                _lblRamPercent.Text = st.RamPercent.HasValue ? $"{st.RamPercent.Value:0}%" : "N/A";
                _lblRamUsed.Text = (st.RamUsedGb.HasValue && st.RamTotalGb.HasValue)
                    ? $"FÍSICA: {st.RamUsedGb.Value:N1} / {st.RamTotalGb.Value:N1} GB"
                    : "FÍSICA: N/A";
                UpdateProgressFill(_barRamTrack, _barRamFill, st.RamPercent);

                // Desempenho / Rede
                _lblFpsValue.Text = (st.Fps.HasValue && st.Fps.Value > 0) ? $"{st.Fps.Value:0}" : "N/A";
                _lblFrametime.Text = st.FrametimeMs.HasValue ? $"{st.FrametimeMs.Value:N1} ms" : "N/A";
                _lblDownload.Text = st.DownloadMbps.HasValue ? $"{st.DownloadMbps.Value:N2} Mb/s" : "N/A";
                _lblUpload.Text = st.UploadMbps.HasValue ? $"{st.UploadMbps.Value:N2} Mb/s" : "N/A";

                DateTime now = DateTime.Now;
                _fpsHistory.Add(new FpsSample
                {
                    Time = now,
                    Value = (st.Fps.HasValue && st.Fps.Value > 0) ? st.Fps : null
                });
                DateTime cutoff = now.AddSeconds(-FpsHistorySeconds);
                _fpsHistory.RemoveAll(s => s.Time < cutoff);
                _chartPanel.Invalidate();

                string status = $"{now:HH:mm:ss}  |  Fonte: {st.Source}";
                if (!string.IsNullOrWhiteSpace(st.StatusHint))
                    status += $"  |  {st.StatusHint}";
                _lblStatus.Text = status;
                _lblStatus.ForeColor = st.Source.Contains("Afterburner") || st.Source.Contains("HWiNFO")
                    ? _green
                    : _textMuted;
            }
            catch (Exception ex)
            {
                _lblStatus.Text = $"Aviso de leitura: {ex.Message}";
                _lblStatus.ForeColor = _orange;
            }
        }

        private void ChartPanel_Paint(object sender, PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(_cardBg);

            int w = _chartPanel.ClientSize.Width;
            int h = _chartPanel.ClientSize.Height;
            if (w < 80 || h < 30) return;

            var validSamples = _fpsHistory.Where(s => s.Value.HasValue).ToList();
            using (var font = new Font("Segoe UI", 8F))
            using (var mutedBrush = new SolidBrush(_textMuted))
            using (var gridPen = new Pen(Color.FromArgb(36, 44, 58), 1F))
            using (var linePen = new Pen(_hotRed, 2F))
            {
                g.DrawString("HISTÓRICO DE FPS (30s)", font, mutedBrush, 12, 8);

                if (validSamples.Count < 2)
                {
                    string msg = "Aguardando captura de FPS em jogo (MSI Afterburner / RTSS / HWiNFO64)...";
                    SizeF sz = g.MeasureString(msg, font);
                    g.DrawString(msg, font, mutedBrush, Math.Max(12, (w - sz.Width) / 2), Math.Max(24, (h - sz.Height) / 2));
                    return;
                }

                int left = 56;
                int right = w - 16;
                int top = 26;
                int bottom = h - 18;
                if (right <= left || bottom <= top) return;

                double maxFps = Math.Max(60.0, validSamples.Max(s => s.Value.Value));
                double scaleMax = Math.Max(60.0, Math.Ceiling((maxFps * 1.1) / 30.0) * 30.0);

                int mid = (top + bottom) / 2;
                g.DrawLine(gridPen, left, top, right, top);
                g.DrawLine(gridPen, left, mid, right, mid);
                g.DrawLine(gridPen, left, bottom, right, bottom);

                g.DrawString($"{scaleMax:0}", font, mutedBrush, 12, top - 6);
                g.DrawString($"{scaleMax / 2:0}", font, mutedBrush, 12, mid - 6);
                g.DrawString("0", font, mutedBrush, 12, bottom - 6);

                DateTime now = DateTime.Now;
                for (int i = 1; i < _fpsHistory.Count; i++)
                {
                    var p0 = _fpsHistory[i - 1];
                    var p1 = _fpsHistory[i];
                    if (!p0.Value.HasValue || !p1.Value.HasValue) continue;

                    double t0 = (p0.Time - now.AddSeconds(-FpsHistorySeconds)).TotalSeconds / FpsHistorySeconds;
                    double t1 = (p1.Time - now.AddSeconds(-FpsHistorySeconds)).TotalSeconds / FpsHistorySeconds;

                    float x0 = (float)(left + Math.Max(0, Math.Min(1, t0)) * (right - left));
                    float x1 = (float)(left + Math.Max(0, Math.Min(1, t1)) * (right - left));
                    float y0 = (float)(bottom - (Math.Min(scaleMax, p0.Value.Value) / scaleMax) * (bottom - top));
                    float y1 = (float)(bottom - (Math.Min(scaleMax, p1.Value.Value) / scaleMax) * (bottom - top));

                    g.DrawLine(linePen, x0, y0, x1, y1);
                }
            }
        }
    }
}

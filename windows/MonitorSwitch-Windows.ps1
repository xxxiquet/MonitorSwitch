param([string]$Config = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
if (!$cfg.macChannel) { $cfg | Add-Member macChannel 2 }
if (!$cfg.returnInput) { $cfg | Add-Member returnInput 16 }
if (!$cfg.monitorModel) { $cfg | Add-Member monitorModel 'G274QPF' }
if ($cfg.channel -notin @(1,2,3) -or $cfg.macChannel -notin @(1,2,3) -or $cfg.channel -eq $cfg.macChannel) { throw 'Choose different valid local and macOS device numbers.' }
if ([int]$cfg.returnInput -lt 1 -or [int]$cfg.returnInput -gt 255) { throw 'Return input must be between 1 and 255.' }
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw 'Windows policy blocks native HID access (Constrained Language Mode). No policy changes were made.'
}

$instanceMutex=[Threading.Mutex]::new($false,('Local\MonitorSwitch-'+$cfg.channel))
try { $ownsMutex=$instanceMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
if(!$ownsMutex){Write-Host 'MonitorSwitch is already running for this channel.'; $instanceMutex.Dispose(); exit}

# Native HID enumeration adapted from marcocosta97/mxswitch (MIT).
# Only feature discovery, device-name reads and getHostInfo are used.
# This script NEVER sends setCurrentHost or ordinary keyboard reports.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.IO;
using System.Threading.Tasks;

public sealed class MonitorSwitchHid : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    struct InterfaceData { public int Size; public Guid Guid; public int Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Detail { public int Size; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=512)] public string Path; }
    [StructLayout(LayoutKind.Sequential)]
    struct Attributes { public int Size; public ushort Vid, Pid, Version; }
    [StructLayout(LayoutKind.Sequential)]
    struct Caps {
        public ushort Usage, UsagePage, InputLen, OutputLen, FeatureLen;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
        public ushort Links, InButtons, InValues, InData, OutButtons, OutValues, OutData, FeatureButtons, FeatureValues, FeatureData;
    }
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(SafeFileHandle h, ref Attributes a);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, ref Caps c);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode)] static extern IntPtr SetupDiGetClassDevsW(ref Guid g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll")] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref InterfaceData a);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr s, ref InterfaceData a, ref Detail d, int size, IntPtr needed, IntPtr info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    public sealed class Endpoint { public string Path; public ushort Pid, InputLen, OutputLen; }
    public static List<Endpoint> Enumerate() {
        var found = new List<Endpoint>(); Guid guid; HidD_GetHidGuid(out guid);
        IntPtr set = SetupDiGetClassDevsW(ref guid, IntPtr.Zero, IntPtr.Zero, 0x12);
        if (set == new IntPtr(-1)) return found;
        try {
            var data = new InterfaceData(); data.Size = Marshal.SizeOf(data);
            for (int i=0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref data); i++) {
                var detail = new Detail(); detail.Size = IntPtr.Size == 8 ? 8 : 6;
                if (!SetupDiGetDeviceInterfaceDetailW(set, ref data, ref detail, Marshal.SizeOf(detail), IntPtr.Zero, IntPtr.Zero)) continue;
                using (var h = CreateFileW(detail.Path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                    if (h.IsInvalid) continue;
                    var attr = new Attributes(); attr.Size = Marshal.SizeOf(attr);
                    if (!HidD_GetAttributes(h, ref attr) || attr.Vid != 0x046d) continue;
                    if (attr.Pid != 0xb36e && attr.Pid != 0xc548) continue;
                    IntPtr p; if (!HidD_GetPreparsedData(h, out p)) continue;
                    var caps = new Caps(); int status = HidP_GetCaps(p, ref caps); HidD_FreePreparsedData(p);
                    // Long-report vendor collection only. Never read key collections.
                    if (status != 0x00110000 || caps.UsagePage < 0xff00 || caps.InputLen < 20 || caps.InputLen > 64 || caps.OutputLen < 20 || caps.OutputLen > 64) continue;
                    found.Add(new Endpoint { Path=detail.Path, Pid=attr.Pid, InputLen=caps.InputLen, OutputLen=caps.OutputLen });
                }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return found;
    }
    FileStream stream; int inLen, outLen; Task<int> pending; byte[] pendingBuffer;
    public MonitorSwitchHid(Endpoint e) {
        var h = CreateFileW(e.Path, 0xc0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
        if (h.IsInvalid) { h.Dispose(); throw new IOException("Cannot open Logitech service interface"); }
        stream = new FileStream(h, FileAccess.ReadWrite, 1, true); inLen=e.InputLen; outLen=e.OutputLen; isBolt=e.Pid==0xc548;
    }
    byte captureSlot, captureFeature; string capturePath, lastCapture; bool isBolt;
    public void EnableCapture(byte slot,byte feature,string path) { captureSlot=slot; captureFeature=feature; capturePath=path; }
    public static bool IsMacSwitchNotification(byte[] report,byte slot,byte feature) {
        // Exact format observed three times on this MX Keys Mini for Business via Bolt.
        // Replies and mere disconnect/power-off never qualify.
        if(feature==0 || report==null || report.Length<20 || report.Length>64 || report[0]!=0x11 || report[1]!=slot || report[2]!=feature || report[3]!=0 || report[4]!=2 || report[5]!=1) return false;
        for(int i=6;i<report.Length;i++) if(report[i]!=0) return false;
        return true;
    }
    void Observe(byte[] report) {
        if(capturePath==null || report.Length<6 || (report[0]!=0x10 && report[0]!=0x11) || report[1]!=captureSlot || report[2]!=captureFeature) return;
        if(isBolt && IsMacSwitchNotification(report,captureSlot,captureFeature)) MonitorSwitchReturnListener.ReturnImmediately("Bolt channel-2 notification");
        string hex=BitConverter.ToString(report).Replace('-', ' ');
        if(hex==lastCapture) return;
        lastCapture=hex;
        string kind=(report[3]&15)==0 ? "NOTIFICATION" : "REPLY";
        string line=DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")+" ChangeHost "+kind+" "+hex;
        Console.WriteLine(line);
        System.IO.File.AppendAllText(capturePath,line+Environment.NewLine);
    }
    byte[] Read(int timeout) {
        // Retain ONE pending read across timeouts: abandoned reads otherwise
        // consume replies intended for the next request.
        if (pending == null) { pendingBuffer=new byte[inLen]; pending=stream.ReadAsync(pendingBuffer,0,inLen); }
        if (Task.WaitAny(new Task[]{pending}, timeout) != 0) return null;
        var task = pending; var buffer = pendingBuffer; pending=null; pendingBuffer=null;
        int n = task.GetAwaiter().GetResult(); if (n == 0) throw new IOException("HID disconnected");
        var result=new byte[n]; Array.Copy(buffer,result,n); Observe(result); return result;
    }
    public byte[] Query(byte device, byte feature, byte function, byte first, byte second) {
        // Discard completed stale packets before issuing a fresh read-only query.
        while (pending != null && pending.IsCompleted) Read(0);
        var frame=new byte[outLen]; frame[0]=0x11; frame[1]=device; frame[2]=feature;
        frame[3]=(byte)((function<<4)|0x0d); frame[4]=first; frame[5]=second;
        var write=stream.WriteAsync(frame,0,frame.Length);
        if (!write.Wait(500)) { Dispose(); throw new IOException("HID write timed out"); }
        write.GetAwaiter().GetResult();
        var deadline=DateTime.UtcNow.AddMilliseconds(500);
        while (DateTime.UtcNow < deadline) {
            var r=Read(50); if (r == null || r.Length<7 || r[1]!=device) continue;
            if ((r[2]==0xff || r[2]==0x8f) && r[3]==feature && r[4]==frame[3]) return null;
            if (r[2]==feature && r[3]==frame[3]) return r;
        }
        return null;
    }
    public void Dispose() { if (stream != null) { stream.Dispose(); stream=null; } }
}
public static class MonitorSwitchDdc {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Physical { public IntPtr Handle; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Description; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Info { public int Size; public int L,T,R,B,WL,WT,WR,WB; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string Device; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Device { public int Size; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string Name; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Description; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Id; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Key; }
    delegate bool Callback(IntPtr monitor,IntPtr dc,IntPtr rect,IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc,IntPtr rect,Callback callback,IntPtr data);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr monitor,ref Info info);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevicesW(string device,uint index,ref Device info,uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor,out uint count);
    [DllImport("dxva2.dll",CharSet=CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor,uint count,[Out] Physical[] physical);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint count,Physical[] physical);
    [DllImport("dxva2.dll",SetLastError=true)] static extern bool SetVCPFeature(IntPtr monitor,byte code,uint value);
    [DllImport("dxva2.dll",SetLastError=true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor,byte code,out uint type,out uint current,out uint maximum);
    [DllImport("dxva2.dll",SetLastError=true)] static extern bool GetCapabilitiesStringLength(IntPtr monitor,out uint length);
    [DllImport("dxva2.dll",CharSet=CharSet.Ansi,SetLastError=true)] static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr monitor,System.Text.StringBuilder text,uint length);
    static string ReadInput(IntPtr monitor) {
        uint type,current,maximum;
        return GetVCPFeatureAndVCPFeatureReply(monitor,0x60,out type,out current,out maximum) ? current.ToString()+" (0x"+current.ToString("X2")+")" : "read failed, error="+Marshal.GetLastWin32Error();
    }
    public static uint ReturnInput = 16;
    public static string MonitorModel = "G274QPF";
    public static string Probe(string instance) { return Inspect(instance,false); }
    public static string ReturnToMac(string instance) { return Inspect(instance,true); }
    static string Inspect(string instance,bool write) {
        bool found=false, sent=false;
        var report=new System.Text.StringBuilder();
        EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,delegate(IntPtr monitor,IntPtr dc,IntPtr rect,IntPtr data) {
            var info=new Info(); info.Size=Marshal.SizeOf(info);
            if (!GetMonitorInfoW(monitor,ref info)) return true;
            var device=new Device(); device.Size=Marshal.SizeOf(device);
            bool match=false;
            if (!String.IsNullOrEmpty(instance)) {
                for (uint index=0; index<16; index++) {
                    device.Size=Marshal.SizeOf(device);
                    if(!EnumDisplayDevicesW(info.Device,index,ref device,1)) break;
                    var path=device.Id.Split('#'); var wmi=instance.Split((char)92);
                    if(path.Length>=3 && wmi.Length>=3 && String.Equals(path[1],wmi[1],StringComparison.OrdinalIgnoreCase) && String.Equals(path[2],wmi[2],StringComparison.OrdinalIgnoreCase)) { match=true; break; }
                }
            }
            uint count; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor,out count) || count==0 || count>16) return true;
            var physical=new Physical[count];
            if (!GetPhysicalMonitorsFromHMONITOR(monitor,count,physical)) return true;
            try { foreach(var p in physical) {
                if (!match && (p.Description==null || p.Description.IndexOf(MonitorModel,StringComparison.OrdinalIgnoreCase)<0)) continue;
                found=true;
                report.Append("Monitor matched: "+p.Description+"; ");
                if (!write) report.Append("input="+ReadInput(p.Handle)+"; ");
                if (!write) {
                    uint length;
                    if (GetCapabilitiesStringLength(p.Handle,out length) && length>0 && length<65536) {
                        var caps=new System.Text.StringBuilder((int)length);
                        if(CapabilitiesRequestAndCapabilitiesReply(p.Handle,caps,length)) report.Append("capabilities="+caps.ToString()+"; ");
                        else report.Append("capabilities failed, error="+Marshal.GetLastWin32Error()+"; ");
                    } else report.Append("capabilities length unavailable; ");
                } else {
                    bool accepted=SetVCPFeature(p.Handle,0x60,ReturnInput);
                    int error=Marshal.GetLastWin32Error();
                    if(accepted) sent=true;
                    report.Append("SetVCP 0x60="+ReturnInput+" accepted="+accepted+", error="+(accepted?0:error)+"; ");
                    report.Append("image not verified; ");
                }
            } } finally { DestroyPhysicalMonitors(count,physical); }
            return true;
        },IntPtr.Zero);
        return report.ToString()+(sent ? "Coordinator input command sent" : (found ? (write ? "Coordinator input DDC write failed" : "probe finished") : "Configured monitor not identified; no display changed"));
    }
}

public static class MonitorSwitchReturnListener {
    static volatile bool running;
    static readonly object gate=new object();
    static string episode="";
    static readonly object ddcGate=new object();
    static string returnedEpisode="", monitorInstance="", diagnosticPath="";
    static bool fastEnabled;
    public static void EnableFastReturn(bool enabled) { fastEnabled=enabled; }
    public static void ReturnImmediately(string source) {
        if(source=="Bolt channel-2 notification" && !fastEnabled) return;
        string current; lock(gate) current=episode;
        if(current.Length==0) return;
        lock(ddcGate) {
            if(current==returnedEpisode) return;
            var clock=System.Diagnostics.Stopwatch.StartNew();
            string result=MonitorSwitchDdc.ReturnToMac(monitorInstance);
            clock.Stop();
            if(result.EndsWith("Coordinator input command sent")) returnedEpisode=current;
            string line=DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")+" "+source+"; "+result+"; DDC duration="+clock.ElapsedMilliseconds+"ms";
            Console.WriteLine(line);
            System.IO.File.AppendAllText(diagnosticPath,line+Environment.NewLine);
        }
    }
    static System.Threading.Thread worker;
    static readonly HashSet<string> seen=new HashSet<string>();
    public static void SetEpisode(string value) { lock(gate) { episode=value; seen.Clear(); } }
    static string Field(string json,string name,string pattern) {
        var matches=System.Text.RegularExpressions.Regex.Matches(json,"\""+name+"\"\\s*:\\s*"+pattern);
        return matches.Count==1 ? matches[0].Groups[1].Value : "";
    }
    public static bool Authenticate(string json,byte[] key,long now) {
        if(json.Length>1024) return false;
        string version=Field(json,"v","(1)(?=\\s*[,}])");
        string input=Field(json,"input","([0-9]{1,3})(?=\\s*[,}])");
        string id=Field(json,"id","\"([a-f0-9]{32})\"");
        string timestamp=Field(json,"time","([0-9]{1,12})(?=\\s*[,}])");
        string packetEpisode=Field(json,"episode","\"([a-f0-9]{32})\"");
        string mac=Field(json,"mac","\"([a-f0-9]{64})\"");
        long time;
        if(version!="1" || input!=MonitorSwitchDdc.ReturnInput.ToString() || id.Length!=32 || mac.Length!=64 || !Int64.TryParse(timestamp,out time) || Math.Abs(now-time)>15) return false;
        string canonical="input|1|"+input+"|"+id+"|"+timestamp+"|"+packetEpisode;
        byte[] digest;
        using(var h=new System.Security.Cryptography.HMACSHA256(key)) digest=h.ComputeHash(System.Text.Encoding.UTF8.GetBytes(canonical));
        string expected=BitConverter.ToString(digest).Replace("-","").ToLowerInvariant();
        int difference=0; for(int i=0;i<64;i++) difference |= expected[i]^mac[i];
        if(difference!=0) return false;
        lock(gate) {
            if(episode.Length==0 || packetEpisode!=episode || seen.Contains(id)) return false;
            if(seen.Count>=256) return false;
            seen.Add(id); return true;
        }
    }
    public static void Start(System.Net.Sockets.UdpClient udp,byte[] key,string macIP,string instance,string logFile) {
        if(running) return;
        monitorInstance=instance; diagnosticPath=logFile;
        udp.Client.ReceiveTimeout=100;
        running=true;
        worker=new System.Threading.Thread(delegate() {
            while(running) {
                try {
                    var sender=new System.Net.IPEndPoint(System.Net.IPAddress.Any,0);
                    byte[] bytes=udp.Receive(ref sender);
                    if(sender.Address.ToString()!=macIP || bytes.Length>1024) continue;
                    string json=System.Text.Encoding.UTF8.GetString(bytes);
                    if(!Authenticate(json,key,DateTimeOffset.UtcNow.ToUnixTimeSeconds())) continue;
                    ReturnImmediately("Mac confirmation");
                } catch(System.Net.Sockets.SocketException) { }
                catch(ObjectDisposedException) { break; }
                catch(Exception e) {
                    Console.WriteLine("Return worker: "+e.Message);
                }
            }
        });
        worker.IsBackground=true; worker.Start();
    }
    public static void Stop() { running=false; if(worker!=null) worker.Join(200); }
}

'@

function Find-Keyboard {
    foreach ($endpoint in [MonitorSwitchHid]::Enumerate()) {
        try { $hid = [MonitorSwitchHid]::new($endpoint) } catch { continue }
        $keep = $false
        try {
            $slots = if ($endpoint.Pid -eq 0xc548) { 1..6 } else { @(255) }
            foreach ($slot in $slots) {
                $feature = $hid.Query($slot,0,0,0x18,0x14)
                if (!$feature -or !$feature[4]) { continue }
                $hostInfo = $hid.Query($slot,$feature[4],0,0,0)
                if (!$hostInfo -or $hostInfo[4] -ne 3 -or $hostInfo[5] -ne ($cfg.channel-1)) { continue }
                $nameFeature = $hid.Query($slot,0,0,0,5)
                if (!$nameFeature -or !$nameFeature[4]) { continue }
                $lengthReply = $hid.Query($slot,$nameFeature[4],0,0,0)
                if (!$lengthReply -or $lengthReply[4] -lt 1 -or $lengthReply[4] -gt 64) { continue }
                $length = [int]$lengthReply[4]; $nameBytes = [System.Collections.Generic.List[byte]]::new()
                while ($nameBytes.Count -lt $length) {
                    $part = $hid.Query($slot,$nameFeature[4],1,$nameBytes.Count,0)
                    if (!$part) { break }
                    $take=[Math]::Min($length-$nameBytes.Count,$part.Length-4)
                    for ($n=0; $n -lt $take; $n++) { $nameBytes.Add($part[4+$n]) }
                }
                $name=[Text.Encoding]::UTF8.GetString($nameBytes.ToArray())
                if ($nameBytes.Count -ne $length -or $name -notmatch 'MX Keys Mini') { continue }
                $keep=$true
                $hid.EnableCapture([byte]$slot,[byte]$feature[4],(Join-Path $PSScriptRoot 'switch-events.log'))
                return [pscustomobject]@{Hid=$hid; Slot=$slot; Feature=$feature[4]; Name=$name}
            }
        } catch { Write-Host ('HID: '+$_.Exception.Message) }
        finally { if (!$keep) { $hid.Dispose() } }
    }
    return $null
}

$udp=[Net.Sockets.UdpClient]::new(0)
$endpoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse($cfg.macIP),[int]$cfg.port)
$key=New-Object byte[] ($cfg.key.Length/2)
for ($i=0; $i -lt $key.Length; $i++) { $key[$i]=[Convert]::ToByte($cfg.key.Substring(2*$i,2),16) }
$hmac=[Security.Cryptography.HMACSHA256]::new($key)
$logFile=Join-Path $PSScriptRoot 'diagnostic.log'
function Log([string]$message) {
    $line=('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date),$message)
    Write-Host $line; Add-Content -LiteralPath $logFile -Value $line
}
$seenCommands=@{}
[MonitorSwitchDdc]::ReturnInput = [uint32]$cfg.returnInput
[MonitorSwitchDdc]::MonitorModel = $cfg.monitorModel
$msiInstance=''
try {
    foreach ($m in Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID) {
        $friendly=-join ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
        if ($friendly.IndexOf($cfg.monitorModel,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $msiInstance=$m.InstanceName -replace '_\d+$',''; break }
    }
} catch { Log 'Monitor identity lookup unavailable; will require configured monitor name from display driver' }
function Announce-Ready {
    $id=[Guid]::NewGuid().ToString('N')
    $stamp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $text="ready|2|$($cfg.channel)|$id|$stamp|$script:episode"
    $mac=[BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','').ToLowerInvariant()
    $packet=@{v=2;channel=[int]$cfg.channel;id=$id;time=$stamp;episode=$script:episode;mac=$mac}|ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($packet)
    [void]$udp.Send($bytes,$bytes.Length,$endpoint)
}
function Announce([bool]$active) {
    $id=[Guid]::NewGuid().ToString('N')
    $stamp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $flag=if ($active) { 1 } else { 0 }
    $text="1|$($cfg.channel)|$flag|$id|$stamp|$script:episode"
    $mac=[BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','').ToLowerInvariant()
    $packet=@{v=1; channel=[int]$cfg.channel; active=$flag; id=$id; time=$stamp; episode=$script:episode; mac=$mac} | ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($packet)
    [void]$udp.Send($bytes,$bytes.Length,$endpoint)
}

Log "MonitorSwitch 0.9.4 receiver ready at startup: channel $($cfg.channel), macOS device $($cfg.macChannel) at $($cfg.macIP). Authenticated coordinator return enabled; no pairing changes."
Log ([MonitorSwitchDdc]::Probe($msiInstance))
$ctx=$null; $active=$false; $good=0; $miss=0; $lastSent=0; $script:episode=[Guid]::NewGuid().ToString('N')
[MonitorSwitchReturnListener]::Start($udp,$key,$cfg.macIP,$msiInstance,$logFile)
[MonitorSwitchReturnListener]::EnableFastReturn($cfg.channel -eq 3 -and $cfg.macChannel -eq 2)
[MonitorSwitchReturnListener]::SetEpisode($script:episode)
Announce-Ready
$lastReady=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Log 'Return receiver ready; initial keyboard connection to channel 3 is not required for Mac requests'
try {
    while ($true) {
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (!$active -and $now-$lastReady -ge 5) { Announce-Ready; $lastReady=$now }
        if (!$ctx) { $ctx=Find-Keyboard }
        $ok=$false
        if ($ctx) {
            try {
                $r=$ctx.Hid.Query($ctx.Slot,$ctx.Feature,0,0,0)
                $ok=($null -ne $r -and $r[4] -eq 3 -and $r[5] -eq ($cfg.channel-1))
            } catch { $ok=$false }
        }
        if ($ok) {
            $miss=0; $good++
            if ($good -ge 2 -and !$active) { $active=$true; $script:episode=[Guid]::NewGuid().ToString('N'); [MonitorSwitchReturnListener]::SetEpisode($script:episode); Log "Keyboard confirmed: $($ctx.Name), channel $($cfg.channel)"; Announce $true; $lastSent=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
            $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($active -and $now-$lastSent -ge 5) { Announce $true; $lastSent=$now }
        } else {
            $good=0; $miss++
            if ($miss -ge 2) {
                if ($active) { $active=$false; Log 'Keyboard left this device'; Announce $false }
                if ($ctx) { $ctx.Hid.Dispose(); $ctx=$null }
            }
        }
        Start-Sleep -Milliseconds 50
    }
} finally { [MonitorSwitchReturnListener]::Stop(); if ($ctx) { $ctx.Hid.Dispose() }; $udp.Dispose(); $hmac.Dispose(); $instanceMutex.ReleaseMutex(); $instanceMutex.Dispose() }

<#
MIT License — native enumeration adapted from https://github.com/marcocosta97/mxswitch
Copyright (c) 2026 Marco Costa
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

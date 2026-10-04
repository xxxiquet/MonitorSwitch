// Native HID enumeration adapted from marcocosta97/mxswitch (MIT).
// See THIRD_PARTY_NOTICES.md and LICENSE. No ordinary keyboard reports are read.
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
        if(running || (worker!=null && worker.IsAlive)) throw new InvalidOperationException("The previous return listener is still stopping.");
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
    public static void Stop() { running=false; if(worker!=null) worker.Join(3000); }
}


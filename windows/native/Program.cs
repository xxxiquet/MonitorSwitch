using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
[assembly: AssemblyVersion("0.10.0.0")]
[assembly: AssemblyFileVersion("0.10.0.0")]
[assembly: AssemblyTitle("MonitorSwitch")]
[assembly: AssemblyDescription("Local Easy-Switch monitor companion")]

public sealed class Profile {
    public string deviceType = "Windows";
    public int channel = 1, macChannel = 2, port = 25347, returnInput = 16;
    public string macIP = "", key = "", monitorModel = "G274QPF";
    public void Validate() {
        IPAddress ip;
        if (deviceType != "Windows") throw new ArgumentException("Configure macOS devices in the macOS app.");
        if (channel < 1 || channel > 3 || macChannel < 1 || macChannel > 3 || channel == macChannel)
            throw new ArgumentException("Choose different device numbers for Windows and the macOS coordinator.");
        if (!IPAddress.TryParse(macIP, out ip) || ip.AddressFamily != AddressFamily.InterNetwork)
            throw new ArgumentException("Enter a valid coordinator IPv4 address.");
        if (!Regex.IsMatch(key ?? "", "\\A[a-fA-F0-9]{64}\\z")) throw new ArgumentException("Import the private Windows profile exported by the Mac app.");
        if (port < 1 || port > 65535 || returnInput < 1 || returnInput > 255 || String.IsNullOrWhiteSpace(monitorModel))
            throw new ArgumentException("Enter a monitor name, a valid port and an input code from 1 to 255.");
        macIP = ip.ToString(); key = key.ToLowerInvariant(); monitorModel = monitorModel.Trim();
    }
    public static Profile Read(string path) {
        if (new FileInfo(path).Length > 16384) throw new ArgumentException("Profile is too large.");
        var profile = new JavaScriptSerializer().Deserialize<Profile>(File.ReadAllText(path));
        if (profile == null) throw new ArgumentException("Empty profile.");
        profile.Validate(); return profile;
    }
    public void Save(string path) {
        Validate(); Directory.CreateDirectory(Path.GetDirectoryName(path));
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            File.WriteAllText(temp, new JavaScriptSerializer().Serialize(this), new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
        } finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

public static class Store {
    public const string Version = "0.10.0-test1";
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MonitorSwitch", "Native");
    public static readonly string Config = Path.Combine(Folder, "config.json");
    public static readonly string Diagnostic = Path.Combine(Folder, "diagnostic.log");
    public static readonly string Events = Path.Combine(Folder, "switch-events.log");
    static readonly object logLock = new object();
    public static void Log(string text) {
        lock (logLock) {
            Directory.CreateDirectory(Folder);
            File.AppendAllText(Diagnostic, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + text + Environment.NewLine);
        }
    }
    public static byte[] Key(Profile profile) {
        return Enumerable.Range(0,32).Select(i=>Convert.ToByte(profile.key.Substring(i*2,2),16)).ToArray();
    }
    public static byte[] Packet(Profile profile, string episode, bool ready, bool active, byte[] key) {
        string id = Guid.NewGuid().ToString("N"); long stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        string canonical = ready ? "ready|2|"+profile.channel+"|"+id+"|"+stamp+"|"+episode
            : "1|"+profile.channel+"|"+(active?1:0)+"|"+id+"|"+stamp+"|"+episode;
        string digest;
        using(var hmac = new HMACSHA256(key)) digest = BitConverter.ToString(hmac.ComputeHash(Encoding.UTF8.GetBytes(canonical))).Replace("-","").ToLowerInvariant();
        var packet = new Dictionary<string, object> { {"v",ready?2:1}, {"channel",profile.channel}, {"id",id}, {"time",stamp}, {"episode",episode}, {"mac",digest} };
        if (!ready) packet["active"] = active?1:0;
        return Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(packet));
    }
}

public sealed class Engine : IDisposable {
    readonly Profile profile;
    Thread thread;
    volatile bool stopping;
    public string State = "Paused";
    public bool IsRunning { get { return thread != null && thread.IsAlive; } }
    public Engine(Profile value) { profile = value; }
    public void Start() {
        if (IsRunning) throw new InvalidOperationException("The previous connection is still stopping.");
        stopping = false; State = "Starting";
        thread = new Thread(Run); thread.IsBackground = true; thread.Name = "MonitorSwitch device connection"; thread.Start();
    }
    public bool Stop() { stopping = true; State = "Stopping"; return thread == null || thread.Join(2500); }
    sealed class Keyboard : IDisposable {
        public MonitorSwitchHid Hid; public byte Slot, Feature; public string Name;
        public void Dispose() { Hid.Dispose(); }
    }
    Keyboard FindKeyboard() {
        foreach (var endpoint in MonitorSwitchHid.Enumerate()) {
            if (stopping) return null;
            MonitorSwitchHid hid;
            try { hid = new MonitorSwitchHid(endpoint); } catch { continue; }
            bool keep = false;
            try {
                byte[] slots = endpoint.Pid == 0xc548 ? new byte[]{1,2,3,4,5,6} : new byte[]{255};
                foreach(byte slot in slots) {
                    if (stopping) return null;
                    byte[] feature = hid.Query(slot,0,0,0x18,0x14);
                    if (feature == null || feature[4] == 0) continue;
                    byte[] host = hid.Query(slot,feature[4],0,0,0);
                    if (host == null || host[4] != 3 || host[5] != profile.channel-1) continue;
                    byte[] nameFeature = hid.Query(slot,0,0,0,5);
                    if (nameFeature == null || nameFeature[4] == 0) continue;
                    byte[] lengthReply = hid.Query(slot,nameFeature[4],0,0,0);
                    if (lengthReply == null || lengthReply[4] < 1 || lengthReply[4] > 64) continue;
                    var nameBytes = new List<byte>(); int length = lengthReply[4];
                    while (nameBytes.Count < length && !stopping) {
                        byte[] part = hid.Query(slot,nameFeature[4],1,(byte)nameBytes.Count,0);
                        if (part == null) break;
                        int take = Math.Min(length-nameBytes.Count,part.Length-4);
                        for(int n=0;n<take;n++) nameBytes.Add(part[4+n]);
                    }
                    string name = Encoding.UTF8.GetString(nameBytes.ToArray());
                    if (stopping || nameBytes.Count != length || name.IndexOf("MX Keys Mini",StringComparison.OrdinalIgnoreCase)<0) continue;
                    hid.EnableCapture(slot,feature[4],Store.Events);
                    keep = true; return new Keyboard { Hid=hid, Slot=slot, Feature=feature[4], Name=name };
                }
            } catch(Exception e) { Store.Log("HID lookup: "+e.Message); }
            finally { if (!keep) hid.Dispose(); }
        }
        return null;
    }
    string MonitorIdentity() {
        try {
            using(var search = new ManagementObjectSearcher("root\\wmi","SELECT InstanceName,UserFriendlyName FROM WmiMonitorID")) {
                search.Options.Timeout = TimeSpan.FromSeconds(3);
                using(var results=search.Get()) foreach(ManagementObject m in results) {
                    using(m) {
                        var chars=(ushort[])m["UserFriendlyName"];
                        string name = new string(chars.Where(c=>c!=0).Select(c=>(char)c).ToArray());
                        if(name.IndexOf(profile.monitorModel,StringComparison.OrdinalIgnoreCase)>=0)
                            return Regex.Replace((string)m["InstanceName"],"_\\d+$","");
                    }
                }
            }
        } catch(Exception e) { Store.Log("Monitor identity unavailable: "+e.Message); }
        return "";
    }
    void Run() {
        Keyboard keyboard = null; UdpClient udp = null; byte[] key = Store.Key(profile);
        bool listener = false;
        try {
            profile.Validate(); udp = new UdpClient(0);
            var endpoint = new IPEndPoint(IPAddress.Parse(profile.macIP),profile.port);
            MonitorSwitchDdc.ReturnInput=(uint)profile.returnInput; MonitorSwitchDdc.MonitorModel=profile.monitorModel;
            string instance = MonitorIdentity();
            string episode = Guid.NewGuid().ToString("N");
            MonitorSwitchReturnListener.SetEpisode(episode);
            MonitorSwitchReturnListener.EnableFastReturn(profile.channel==3 && profile.macChannel==2);
            MonitorSwitchReturnListener.Start(udp,key,profile.macIP,instance,Store.Diagnostic); listener=true;
            Action<bool,bool> announce = delegate(bool ready,bool active) {
                byte[] bytes=Store.Packet(profile,episode,ready,active,key); udp.Send(bytes,bytes.Length,endpoint);
            };
            announce(true,false);
            Store.Log("MonitorSwitch "+Store.Version+" | native application | device "+profile.channel+" | receiver ready");
            Store.Log(MonitorSwitchDdc.Probe(instance));
            int good=0,miss=0; bool activeState=false;
            long lastReady=DateTimeOffset.UtcNow.ToUnixTimeSeconds(),lastSent=0;
            while(!stopping) {
                long now=DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                if(!activeState && now-lastReady>=5) { announce(true,false); lastReady=now; }
                if(keyboard==null) keyboard=FindKeyboard();
                bool ok=false;
                if(keyboard!=null && !stopping) {
                    try { byte[] r=keyboard.Hid.Query(keyboard.Slot,keyboard.Feature,0,0,0); ok=r!=null && r[4]==3 && r[5]==profile.channel-1; } catch { ok=false; }
                }
                if(ok) {
                    miss=0; good++;
                    if(good>=2 && !activeState) {
                        activeState=true; episode=Guid.NewGuid().ToString("N"); MonitorSwitchReturnListener.SetEpisode(episode);
                        Store.Log("Keyboard confirmed: "+keyboard.Name+", channel "+profile.channel);
                        announce(false,true); lastSent=DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                    }
                    now=DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                    if(activeState && now-lastSent>=5) { announce(false,true); lastSent=now; }
                } else {
                    good=0; miss++;
                    if(miss>=2) {
                        if(activeState) { activeState=false; Store.Log("Keyboard left this device"); announce(false,false); }
                        if(keyboard!=null) { keyboard.Dispose(); keyboard=null; }
                    }
                }
                State=activeState ? "Keyboard on device "+profile.channel : "Ready | waiting for keyboard";
                Thread.Sleep(50);
            }
            if(activeState) announce(false,false);
        } catch(Exception e) { State="Stopped: "+e.Message; Store.Log("Connection stopped: "+e.Message); }
        finally {
            if(listener) MonitorSwitchReturnListener.Stop();
            if(keyboard!=null) keyboard.Dispose(); if(udp!=null) udp.Dispose(); Array.Clear(key,0,key.Length);
            if(stopping) State="Paused";
        }
    }
    public void Dispose() { Stop(); }
}

public sealed class SetupForm : Form {
    readonly Dictionary<string,Control> fields = new Dictionary<string,Control>();
    readonly Label error = new Label();
    public Profile Result;
    public SetupForm(Profile profile) {
        Text="MonitorSwitch | Device setup"; Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        ClientSize=new Size(510,450); StartPosition=FormStartPosition.CenterScreen; FormBorderStyle=FormBorderStyle.FixedDialog; MaximizeBox=false; MinimizeBox=false;
        string[] names={"deviceType","channel","macChannel","macIP","key","returnInput","monitorModel","port"};
        string[] labels={"System","This device","macOS coordinator","Coordinator IPv4 address","Pairing key","Coordinator monitor input","Windows monitor name","UDP port"};
        for(int i=0;i<names.Length;i++) {
            var label=new Label {Text=labels[i]};label.SetBounds(20,25+i*36,190,25);Controls.Add(label);
            Control control;
            if(i<3) { var combo=new ComboBox { DropDownStyle=ComboBoxStyle.DropDownList }; combo.Items.AddRange(i==0?new object[]{"Windows","macOS"}:new object[]{"1","2","3"});control=combo; }
            else control=new TextBox { UseSystemPasswordChar=names[i]=="key" };
            control.SetBounds(220,20+i*36,265,26);Controls.Add(control);fields[names[i]]=control;
        }
        error.ForeColor=Color.Firebrick;error.SetBounds(20,320,465,65);Controls.Add(error);
        var import=new Button {Text="Import profile..."}; import.SetBounds(20,400,140,30);Controls.Add(import);import.Click+=Import;
        var save=new Button {Text="Save"};save.SetBounds(300,400,85,30);Controls.Add(save);save.Click+=Save;
        var cancel=new Button {Text="Cancel",DialogResult=DialogResult.Cancel};cancel.SetBounds(400,400,85,30);Controls.Add(cancel);CancelButton=cancel;
        Fill(profile??new Profile());
    }
    protected override void Dispose(bool disposing) {if(disposing && Icon!=null){Icon.Dispose();Icon=null;}base.Dispose(disposing);}
    void Fill(Profile value) { foreach(var pair in fields) pair.Value.Text=Convert.ToString(typeof(Profile).GetField(pair.Key).GetValue(value)); }
    void Import(object sender,EventArgs args) {
        using(var dialog=new OpenFileDialog {Filter="MonitorSwitch profile (*.json)|*.json"}) {
            if(dialog.ShowDialog(this)!=DialogResult.OK)return;
            try { Fill(Profile.Read(dialog.FileName));error.Text=""; } catch(Exception e) {error.Text=e.Message;}
        }
    }
    void Save(object sender,EventArgs args) {
        try {
            var profile=new Profile();
            foreach(var pair in fields) {
                FieldInfo field=typeof(Profile).GetField(pair.Key);
                field.SetValue(profile,field.FieldType==typeof(int)?(object)Int32.Parse(pair.Value.Text):pair.Value.Text);
            }
            profile.Validate(); Result=profile; DialogResult=DialogResult.OK; Close();
        } catch(Exception e) {error.Text=e.Message;}
    }
}

public static class Startup {
    static readonly string InstalledExe=Path.Combine(Store.Folder,"MonitorSwitch.exe");
    static string Link(int channel) {return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup),"MonitorSwitch-Device"+channel+".lnk");}
    static object Shortcut(string path) {
        Type type=Type.GetTypeFromProgID("WScript.Shell");object shell=Activator.CreateInstance(type);
        try { return type.InvokeMember("CreateShortcut",BindingFlags.InvokeMethod,null,shell,new object[]{path}); }
        finally {Marshal.FinalReleaseComObject(shell);}
    }
    static object Get(object obj,string name) {return obj.GetType().InvokeMember(name,BindingFlags.GetProperty,null,obj,null);}
    static void Set(object obj,string name,object value) {obj.GetType().InvokeMember(name,BindingFlags.SetProperty,null,obj,new object[]{value});}
    public static bool Enabled(int channel) {
        if(!File.Exists(Link(channel)))return false;
        object link=Shortcut(Link(channel));
        try {return String.Equals(Convert.ToString(Get(link,"TargetPath")),InstalledExe,StringComparison.OrdinalIgnoreCase) && String.IsNullOrWhiteSpace(Convert.ToString(Get(link,"Arguments")));}
        finally {Marshal.FinalReleaseComObject(link);}
    }
    public static void Enable(Profile profile) {
        Directory.CreateDirectory(Store.Folder);
        if(!String.Equals(Application.ExecutablePath,InstalledExe,StringComparison.OrdinalIgnoreCase))File.Copy(Application.ExecutablePath,InstalledExe,true);
        profile.Save(Store.Config);
        object link=Shortcut(Link(profile.channel));
        try { Set(link,"TargetPath",InstalledExe);Set(link,"Arguments","");Set(link,"WorkingDirectory",Store.Folder);Set(link,"IconLocation",InstalledExe+",0");Set(link,"Description","MonitorSwitch native application");link.GetType().InvokeMember("Save",BindingFlags.InvokeMethod,null,link,null); }
        finally {Marshal.FinalReleaseComObject(link);}
    }
    public static void Disable(int channel) { if(Enabled(channel))File.Delete(Link(channel)); }
}

public sealed class TrayContext : ApplicationContext {
    readonly NotifyIcon tray=new NotifyIcon(); readonly ContextMenuStrip menu=new ContextMenuStrip();
    readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    readonly ToolStripMenuItem status,follow,startup;
    Profile profile; Engine engine;
    public TrayContext(Profile value) {
        profile=value;tray.Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);tray.Text="MonitorSwitch | Device "+profile.channel;
        var title=menu.Items.Add("MonitorSwitch | Device "+profile.channel);title.Enabled=false;
        status=(ToolStripMenuItem)menu.Items.Add("Starting...");status.Enabled=false;menu.Items.Add(new ToolStripSeparator());
        follow=(ToolStripMenuItem)menu.Items.Add("Follow Easy-Switch");follow.Click+=delegate{if(engine!=null && engine.IsRunning)engine.Stop();else Start();};
        var setup=menu.Items.Add("Setup device...");setup.Click+=Setup;
        startup=(ToolStripMenuItem)menu.Items.Add("Launch at sign-in");startup.Click+=delegate{Try(delegate{if(Startup.Enabled(profile.channel))Startup.Disable(profile.channel);else Startup.Enable(profile);Refresh();});};
        var diagnostics=new ToolStripMenuItem("Diagnostics");
        diagnostics.DropDownItems.Add("Open logs folder",null,delegate{Try(delegate{System.Diagnostics.Process.Start(Store.Folder);});});
        diagnostics.DropDownItems.Add("Export diagnostics...",null,delegate{Try(ExportDiagnostics);});menu.Items.Add(diagnostics);
        menu.Items.Add("About MonitorSwitch",null,delegate{MessageBox.Show("MonitorSwitch "+Store.Version+"\n\nOne local Windows process. No PowerShell, service, cloud or administrator installer.\n\nUnsigned test build: antivirus compatibility is not verified.","MonitorSwitch");});
        menu.Items.Add(new ToolStripSeparator());menu.Items.Add("Quit MonitorSwitch",null,delegate{ExitThread();});
        tray.ContextMenuStrip=menu;tray.Visible=true;timer.Interval=1000;timer.Tick+=delegate{Refresh();};timer.Start();Start();
    }
    void Try(Action action) {try{action();}catch(Exception e){MessageBox.Show(e.Message,"MonitorSwitch",MessageBoxButtons.OK,MessageBoxIcon.Error);}}
    void Start() {Try(delegate{if(engine!=null && engine.IsRunning)throw new InvalidOperationException("Connection is still stopping.");engine=new Engine(profile);engine.Start();});}
    void Refresh() {follow.Checked=engine!=null && engine.IsRunning;status.Text=engine==null?"Paused":engine.State;try{startup.Checked=Startup.Enabled(profile.channel);}catch{startup.Checked=false;}}
    void Setup(object sender,EventArgs args) {
        Try(delegate{
            bool wasRunning=engine!=null && engine.IsRunning;
            if(engine!=null && !engine.Stop())throw new InvalidOperationException("Connection is still stopping. Try setup again in a moment.");
            try { using(var form=new SetupForm(profile)) {
                if(form.ShowDialog()==DialogResult.OK) {
                    bool wasStartup=Startup.Enabled(profile.channel);int oldChannel=profile.channel;Profile next=form.Result; next.Save(Store.Config);
                    profile=next;
                    if(wasStartup) {Startup.Enable(next);if(next.channel!=oldChannel)Startup.Disable(oldChannel);}
                    tray.Text="MonitorSwitch | Device "+profile.channel;menu.Items[0].Text=tray.Text;
                }
            }
            } finally {if(wasRunning)Start();Refresh();}
        });
    }
    void ExportDiagnostics() {
        using(var dialog=new SaveFileDialog {Filter="ZIP archive (*.zip)|*.zip",FileName="MonitorSwitch-diagnostics-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+".zip"}) {
            if(dialog.ShowDialog()!=DialogResult.OK)return;
            using(var stream=new FileStream(dialog.FileName,FileMode.Create)) using(var zip=new ZipArchive(stream,ZipArchiveMode.Create)) {
                foreach(string name in new[]{"diagnostic.log","switch-events.log"}) {
                    string path=Path.Combine(Store.Folder,name);if(!File.Exists(path))continue;
                    var entry=zip.CreateEntry(name);
                    using(var source=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var destination=entry.Open())source.CopyTo(destination);
                }
                using(var writer=new StreamWriter(zip.CreateEntry("summary.txt").Open()))writer.Write("MonitorSwitch "+Store.Version+"\nDevice: "+profile.channel+"\nWindows: "+Environment.OSVersion+"\nRuntime: "+Environment.Version+"\nPairing keys and configuration excluded. Logs may contain local IP addresses and hardware identifiers.\n");
            }
            MessageBox.Show("Diagnostics saved. Review before sharing: logs may contain local addresses and device identifiers.","MonitorSwitch");
        }
    }
    protected override void ExitThreadCore() {timer.Stop();if(engine!=null)engine.Dispose();tray.Visible=false;tray.Icon.Dispose();tray.Dispose();timer.Dispose();menu.Dispose();base.ExitThreadCore();}
}

public static class Program {
    [STAThread]
    public static int Main(string[] args) {
        Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
        if(args.Length>0 && args[0]=="--self-test")return SelfTest(args.Length>1?args[1]:"self-test-result.txt");
        using(var mutex=new Mutex(false,"Local\\MonitorSwitch-Native")) {
            bool owner;try{owner=mutex.WaitOne(0);}catch(AbandonedMutexException){owner=true;}
            if(!owner){MessageBox.Show("MonitorSwitch is already running. Open its icon near the clock.","MonitorSwitch");return 0;}
            try {
                Directory.CreateDirectory(Store.Folder);Profile profile=null;
                try {
                    if(File.Exists(Store.Config))profile=Profile.Read(Store.Config);
                    else {string preset=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"config.json");if(File.Exists(preset)){profile=Profile.Read(preset);profile.Save(Store.Config);}}
                }catch(Exception e){MessageBox.Show("Setup needs attention: "+e.Message,"MonitorSwitch");}
                if(profile==null)using(var setup=new SetupForm(null)){if(setup.ShowDialog()!=DialogResult.OK)return 0;profile=setup.Result;profile.Save(Store.Config);}
                Application.Run(new TrayContext(profile));return 0;
            }catch(Exception e){MessageBox.Show(e.Message,"MonitorSwitch",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
            finally {mutex.ReleaseMutex();}
        }
    }
    static int SelfTest(string report) {
        try {
            var profile=new Profile {channel=3,macIP="192.0.2.1",key=new string('a',64)};profile.Validate();
            profile.channel=2;bool rejected=false;try{profile.Validate();}catch(ArgumentException){rejected=true;}if(!rejected)throw new Exception("Duplicate channels accepted");profile.channel=3;
            using(var form=new SetupForm(profile)){if(form.Controls.Count<18)throw new Exception("Setup form incomplete");}
            using(var icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath)){if(icon==null || icon.Width<16)throw new Exception("Embedded icon missing");}
            byte[] notification=new byte[20];notification[0]=0x11;notification[1]=1;notification[2]=9;notification[4]=2;notification[5]=1;
            if(!MonitorSwitchHid.IsMacSwitchNotification(notification,1,9))throw new Exception("Bolt notification not recognized");
            notification[3]=13;if(MonitorSwitchHid.IsMacSwitchNotification(notification,1,9))throw new Exception("Query reply accepted as button notification");
            byte[] key=Store.Key(profile);string episode=new string('b',32),id=new string('c',32);long now=1000;
            MonitorSwitchDdc.ReturnInput=17;MonitorSwitchReturnListener.SetEpisode(episode);
            string canonical="input|1|17|"+id+"|1000|"+episode,digest;
            using(var h=new HMACSHA256(key))digest=BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(canonical))).Replace("-","").ToLowerInvariant();
            string packet=new JavaScriptSerializer().Serialize(new Dictionary<string,object>{{"v",1},{"input",17},{"id",id},{"time",now},{"episode",episode},{"mac",digest}});
            if(!MonitorSwitchReturnListener.Authenticate(packet,key,now))throw new Exception("Valid signed input rejected");
            if(MonitorSwitchReturnListener.Authenticate(packet,key,now))throw new Exception("Replayed input accepted");
            MonitorSwitchReturnListener.SetEpisode(episode);if(MonitorSwitchReturnListener.Authenticate(packet,key,now+60))throw new Exception("Stale input accepted");
            byte[] ready=Store.Packet(profile,episode,true,false,key);var readyObject=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(ready));if((int)readyObject["v"]!=2 || readyObject.ContainsKey("active"))throw new Exception("Readiness format changed");
            string temp=Path.Combine(Path.GetTempPath(),"MonitorSwitch-test-"+Guid.NewGuid().ToString("N"));
            try {profile.Save(Path.Combine(temp,"config.json"));profile.Save(Path.Combine(temp,"config.json"));if(Profile.Read(Path.Combine(temp,"config.json")).key!=profile.key)throw new Exception("Profile persistence failed");}finally{if(Directory.Exists(temp))Directory.Delete(temp,true);}
            byte[] active=Store.Packet(profile,episode,false,true,key),inactive=Store.Packet(profile,episode,false,false,key);
            File.WriteAllText(report+".packets.json",new JavaScriptSerializer().Serialize(new Dictionary<string,object>{{"key",profile.key},{"packets",new[]{Encoding.UTF8.GetString(ready),Encoding.UTF8.GetString(active),Encoding.UTF8.GetString(inactive)}}}));
            File.WriteAllText(report,"PASS: profile validation, setup form, embedded icon, exact Bolt notification, signed DDC input, replay/stale rejection, readiness packet.\n");return 0;
        }catch(Exception e){File.WriteAllText(report,"FAIL: "+e+"\n");return 1;}
    }
}

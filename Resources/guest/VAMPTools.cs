// VAMP Tools: shared clipboard between the Mac and this Windows VM.
//
// Talks to VAMP over a virtio-serial port (\\.\Global\org.vamp.clipboard). Frames in both directions:
//   [u32 LE type][u32 LE length][payload]
//   1 TEXT   UTF-8 text           2 PNG    PNG image
//   3 TIME   Mac's clock, i64 LE milliseconds since 1970 UTC (sent on connect and after the Mac wakes:
//            a sleeping Mac pauses the VM, so Windows would otherwise wake up hours behind)
//   16 HELLO host asks "who's there"   17 READY  agent is listening (payload: version)
// Compiled inside the guest by install.ps1 with the C# compiler that ships with Windows
// (no downloads, no third-party binaries), and started at sign-in from HKCU\...\Run.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Management;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace VAMPTools
{
    static class Native
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(SafeFileHandle h, IntPtr buf, int n, IntPtr read, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteFile(SafeFileHandle h, IntPtr buf, int n, IntPtr written, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetOverlappedResult(SafeFileHandle h, IntPtr ov, out int n, bool wait);
        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();

        [StructLayout(LayoutKind.Sequential)]
        public struct SYSTEMTIME { public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds; }
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetSystemTime(ref SYSTEMTIME t);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct TOKEN_PRIVILEGES { public uint Count; public long Luid; public uint Attributes; }
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool LookupPrivilegeValue(string system, string name, out long luid);
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int len, IntPtr prev, IntPtr retLen);
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr h);

        /// Sets the clock (UTC). Elevated admins hold SeSystemtimePrivilege but it starts disabled.
        public static bool SetClock(DateTime utc)
        {
            IntPtr token;
            if (OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) // ADJUST_PRIVILEGES | QUERY
            {
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.Count = 1;
                tp.Attributes = 2; // SE_PRIVILEGE_ENABLED
                if (LookupPrivilegeValue(null, "SeSystemtimePrivilege", out tp.Luid))
                    AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                CloseHandle(token);
            }
            SYSTEMTIME st = new SYSTEMTIME();
            st.Year = (ushort)utc.Year; st.Month = (ushort)utc.Month; st.Day = (ushort)utc.Day;
            st.Hour = (ushort)utc.Hour; st.Minute = (ushort)utc.Minute; st.Second = (ushort)utc.Second;
            st.Milliseconds = (ushort)utc.Millisecond;
            return SetSystemTime(ref st);
        }
    }

    /// The virtio-serial port, opened for overlapped I/O so a read can wait while a write goes out.
    sealed class Port : IDisposable
    {
        readonly SafeFileHandle h;
        Port(SafeFileHandle h) { this.h = h; }

        public static Port Open(string name, out int error)
        {
            error = 0;
            const uint GENERIC_RW = 0xC0000000, OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
            SafeFileHandle h = Native.CreateFile(@"\\.\Global\" + name, GENERIC_RW, 0, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h.IsInvalid) { error = Marshal.GetLastWin32Error(); h.Dispose(); return null; }
            return new Port(h);
        }

        /// One overlapped read or write; bytes transferred, or -1 on error.
        public int Io(bool write, IntPtr buf, int n)
        {
            if (h.IsClosed) return -1;
            IntPtr ov = Marshal.AllocHGlobal(64);
            try
            {
                using (ManualResetEvent ev = new ManualResetEvent(false))
                {
                    for (int i = 0; i < 64; i++) Marshal.WriteByte(ov, i, 0);
                    Marshal.WriteIntPtr(ov, 2 * IntPtr.Size + 8, ev.SafeWaitHandle.DangerousGetHandle()); // OVERLAPPED.hEvent
                    bool ok = write ? Native.WriteFile(h, buf, n, IntPtr.Zero, ov) : Native.ReadFile(h, buf, n, IntPtr.Zero, ov);
                    if (!ok && Marshal.GetLastWin32Error() != 997) return -1; // 997 = ERROR_IO_PENDING
                    int done;
                    if (!Native.GetOverlappedResult(h, ov, out done, true)) return -1;
                    return done;
                }
            }
            catch (ObjectDisposedException) { return -1; } // closed by the reader while this write waited
            finally { Marshal.FreeHGlobal(ov); }
        }

        public bool WriteAll(byte[] data)
        {
            IntPtr buf = Marshal.AllocHGlobal(Math.Max(1, data.Length));
            try
            {
                Marshal.Copy(data, 0, buf, data.Length);
                int off = 0;
                while (off < data.Length)
                {
                    int n = Io(true, buf + off, data.Length - off);
                    if (n <= 0) return false;
                    off += n;
                }
                return true;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public void Dispose() { h.Dispose(); }
    }

    sealed class Agent
    {
        const string PortName = "org.vamp.clipboard";
        const string Version = "VAMPTools/1";
        const uint TEXT = 1, PNG = 2, TIME = 3, HELLO = 16, READY = 17;
        const int MaxPayload = 64 << 20;

        readonly Control ui = new Control();
        readonly object portLock = new object();
        Port port;
        uint lastSeq;
        int lastErr = -1;

        internal static void Log(string line)
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VAMP Tools");
                Directory.CreateDirectory(dir);
                string f = Path.Combine(dir, "VAMPTools.log");
                if (File.Exists(f) && new FileInfo(f).Length > 256 * 1024) File.Delete(f);
                File.AppendAllText(f, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + line + "\r\n");
            }
            catch (Exception) { }
        }

        // Latest outgoing frame only: if the Mac isn't reading, older clipboard contents are dropped, never queued.
        readonly object outLock = new object();
        readonly AutoResetEvent outReady = new AutoResetEvent(false);
        byte[] outFrame;
        readonly Queue<byte[]> control = new Queue<byte[]>();

        public Agent()
        {
            IntPtr force = ui.Handle; // creates the window so BeginInvoke works
            lastSeq = Native.GetClipboardSequenceNumber();
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = 250;
            t.Tick += delegate { Poll(); };
            t.Start();
            Start(PortLoop);
            Start(WriteLoop);
            Start(delegate { Thread.Sleep(10000); CheckForUpdate(); });
        }

        /// VAMP ships the agent's source on CD 2; when that differs from the installed copy, reinstall from
        /// the disc (we're elevated, so no prompt) and step aside. The installer runs outside this task's
        /// process tree (via WMI) so stopping the task doesn't stop the installer too.
        static void CheckForUpdate()
        {
            string mine = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "VAMPTools.cs");
            foreach (DriveInfo d in DriveInfo.GetDrives())
            {
                if (d.DriveType != DriveType.CDRom || !d.IsReady) continue;
                string dir = Path.Combine(d.RootDirectory.FullName, "VAMP Tools");
                string src = Path.Combine(dir, "VAMPTools.cs"), installer = Path.Combine(dir, "install.ps1");
                if (!File.Exists(src) || !File.Exists(installer)) continue;
                if (File.Exists(mine) && File.ReadAllText(src) == File.ReadAllText(mine)) return;
                Log("newer VAMP Tools on " + d.Name + ", updating");
                using (ManagementClass proc = new ManagementClass("Win32_Process"))
                {
                    proc.InvokeMethod("Create", new object[] { "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + installer + "\"", null, null, null });
                }
                return;
            }
        }

        /// Background threads never take the process down: a failure is logged and the loop starts over.
        static void Start(ThreadStart f)
        {
            Thread th = new Thread(delegate ()
            {
                while (true)
                {
                    try { f(); return; }
                    catch (Exception e) { Log("thread error: " + e.GetType().Name + ": " + e.Message); Thread.Sleep(1000); }
                }
            });
            th.IsBackground = true;
            th.Start();
        }

        static byte[] Frame(uint type, byte[] payload)
        {
            byte[] f = new byte[8 + payload.Length];
            BitConverter.GetBytes(type).CopyTo(f, 0);
            BitConverter.GetBytes((uint)payload.Length).CopyTo(f, 4);
            payload.CopyTo(f, 8);
            return f;
        }

        void SendClipboard(byte[] frame) { lock (outLock) { outFrame = frame; } outReady.Set(); }
        void SendControl(byte[] frame) { lock (outLock) { control.Enqueue(frame); } outReady.Set(); }

        void WriteLoop()
        {
            while (true)
            {
                outReady.WaitOne();
                while (true)
                {
                    byte[] f = null;
                    lock (outLock)
                    {
                        if (control.Count > 0) f = control.Dequeue();
                        else if (outFrame != null) { f = outFrame; outFrame = null; }
                    }
                    if (f == null) break;
                    Port p;
                    lock (portLock) p = port;
                    if (p != null) p.WriteAll(f);
                }
            }
        }

        void PortLoop()
        {
            while (true)
            {
                int err;
                Port p = Port.Open(PortName, out err);
                if (p == null) { if (err != lastErr) Log("can't open port: error " + err); lastErr = err; Thread.Sleep(3000); continue; }
                if (lastErr != 0) Log("port open");
                lastErr = 0;
                lock (portLock) port = p;
                SendControl(Frame(READY, Encoding.UTF8.GetBytes(Version)));
                try { ReadFrames(p); }
                finally
                {
                    lock (portLock) port = null;
                    p.Dispose();
                }
                Thread.Sleep(1000);
            }
        }

        void ReadFrames(Port p)
        {
            const int Chunk = 64 * 1024;
            IntPtr buf = Marshal.AllocHGlobal(Chunk);
            MemoryStream acc = new MemoryStream();
            try
            {
                while (true)
                {
                    int n = p.Io(false, buf, Chunk);
                    if (n < 0) return;
                    if (n == 0) { Thread.Sleep(50); continue; }
                    byte[] got = new byte[n];
                    Marshal.Copy(buf, got, 0, n);
                    acc.Write(got, 0, n);
                    while (true)
                    {
                        byte[] all = acc.GetBuffer();
                        long len = acc.Length;
                        if (len < 8) break;
                        uint type = BitConverter.ToUInt32(all, 0);
                        uint size = BitConverter.ToUInt32(all, 4);
                        if (size > MaxPayload || (type != TEXT && type != PNG && type != TIME && type != HELLO && type != READY)) return; // lost sync: reopen
                        if (len < 8 + size) break;
                        byte[] payload = new byte[size];
                        Array.Copy(all, 8, payload, 0, size);
                        MemoryStream rest = new MemoryStream();
                        rest.Write(all, 8 + (int)size, (int)(len - 8 - size));
                        acc = rest;
                        Handle(type, payload);
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        void Handle(uint type, byte[] payload)
        {
            if (type == HELLO) { SendControl(Frame(READY, Encoding.UTF8.GetBytes(Version))); return; }
            if (type == TIME)
            {
                if (payload.Length != 8) return;
                DateTime mac = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(BitConverter.ToInt64(payload, 0));
                double off = (DateTime.UtcNow - mac).TotalSeconds;
                if (Math.Abs(off) > 2)
                {
                    bool ok = Native.SetClock(mac);
                    Log(string.Format("clock was {0:0.0}s off; set from the Mac: {1}", off, ok ? "ok" : "error " + Marshal.GetLastWin32Error()));
                }
                return;
            }
            if (type == TEXT)
            {
                string text = Encoding.UTF8.GetString(payload).Replace("\r\n", "\n").Replace("\n", "\r\n");
                ui.BeginInvoke((MethodInvoker)delegate { SetText(text); });
            }
            else if (type == PNG)
            {
                ui.BeginInvoke((MethodInvoker)delegate { SetImage(payload); });
            }
        }

        void SetText(string text)
        {
            try
            {
                if (Clipboard.ContainsText(TextDataFormat.UnicodeText) && Clipboard.GetText(TextDataFormat.UnicodeText) == text) return;
                if (text.Length == 0) Clipboard.Clear();
                else Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), true, 10, 50);
            }
            catch (Exception) { }
            lastSeq = Native.GetClipboardSequenceNumber();
        }

        void SetImage(byte[] png)
        {
            try
            {
                using (MemoryStream ms = new MemoryStream(png))
                using (Bitmap bmp = new Bitmap(ms))
                {
                    DataObject d = new DataObject();
                    d.SetData(DataFormats.Bitmap, true, new Bitmap(bmp));
                    d.SetData("PNG", false, new MemoryStream(png));
                    Clipboard.SetDataObject(d, true, 10, 50);
                }
            }
            catch (Exception) { }
            lastSeq = Native.GetClipboardSequenceNumber();
        }

        void Poll()
        {
            uint seq = Native.GetClipboardSequenceNumber();
            if (seq == lastSeq) return;
            try
            {
                IDataObject d = Clipboard.GetDataObject();
                lastSeq = seq;
                if (d == null) return;
                if (d.GetDataPresent(DataFormats.UnicodeText))
                {
                    string s = d.GetData(DataFormats.UnicodeText) as string;
                    if (s == null) return;
                    byte[] utf8 = Encoding.UTF8.GetBytes(s.Replace("\r\n", "\n"));
                    if (utf8.Length <= MaxPayload) SendClipboard(Frame(TEXT, utf8));
                }
                else if (d.GetDataPresent("PNG"))
                {
                    MemoryStream ms = d.GetData("PNG") as MemoryStream;
                    if (ms != null && ms.Length <= MaxPayload) SendClipboard(Frame(PNG, ms.ToArray()));
                }
                else if (d.GetDataPresent(DataFormats.Bitmap))
                {
                    Image img = d.GetData(DataFormats.Bitmap) as Image;
                    if (img != null)
                    {
                        using (MemoryStream ms = new MemoryStream())
                        {
                            img.Save(ms, ImageFormat.Png);
                            if (ms.Length <= MaxPayload) SendClipboard(Frame(PNG, ms.ToArray()));
                        }
                        img.Dispose();
                    }
                }
            }
            catch (Exception) { lastSeq = 0; } // clipboard busy (another app has it open): try again next tick
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool first;
            Mutex one = new Mutex(true, @"Local\VAMPTools", out first);
            if (!first) return;
            AppDomain.CurrentDomain.UnhandledException += delegate (object s, UnhandledExceptionEventArgs e) { Agent.Log("crash: " + e.ExceptionObject); };
            Application.ThreadException += delegate (object s, ThreadExceptionEventArgs e) { Agent.Log("ui error: " + e.Exception.Message); };
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            new Agent();
            Application.Run();
            GC.KeepAlive(one);
        }
    }
}

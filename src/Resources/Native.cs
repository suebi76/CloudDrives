// Small native helpers for CloudDrives, compiled at runtime with Add-Type.
// Must stay compatible with the C# 5 compiler used by Windows PowerShell 5.1.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CloudDrives.Native
{
    // Generic credentials in the Windows Credential Manager. Windows protects them with DPAPI
    // for the current user; other users on the machine cannot read them.
    public static class CredentialStore
    {
        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2;
        private const int ERROR_NOT_FOUND = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredWriteW")]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredReadW")]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredDeleteW")]
        private static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr buffer);

        public static void Write(string target, string userName, string secret, string comment)
        {
            byte[] blob = Encoding.Unicode.GetBytes(secret);
            if (blob.Length > 2560)
            {
                throw new ArgumentException("Secret is too large for the Windows credential store.");
            }
            IntPtr blobPtr = Marshal.AllocHGlobal(Math.Max(blob.Length, 1));
            try
            {
                Marshal.Copy(blob, 0, blobPtr, blob.Length);
                CREDENTIAL credential = new CREDENTIAL();
                credential.Type = CRED_TYPE_GENERIC;
                credential.TargetName = target;
                credential.UserName = userName;
                credential.Comment = comment;
                credential.CredentialBlob = blobPtr;
                credential.CredentialBlobSize = blob.Length;
                credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
                if (!CredWrite(ref credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                for (int i = 0; i < blob.Length; i++)
                {
                    Marshal.WriteByte(blobPtr, i, 0);
                }
                Marshal.FreeHGlobal(blobPtr);
                Array.Clear(blob, 0, blob.Length);
            }
        }

        public static string Read(string target)
        {
            IntPtr pointer;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out pointer))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_FOUND)
                {
                    return null;
                }
                throw new Win32Exception(error);
            }
            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(pointer, typeof(CREDENTIAL));
                if (credential.CredentialBlobSize == 0 || credential.CredentialBlob == IntPtr.Zero)
                {
                    return string.Empty;
                }
                return Marshal.PtrToStringUni(credential.CredentialBlob, credential.CredentialBlobSize / 2);
            }
            finally
            {
                CredFree(pointer);
            }
        }

        public static bool Delete(string target)
        {
            if (CredDelete(target, CRED_TYPE_GENERIC, 0))
            {
                return true;
            }
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_NOT_FOUND)
            {
                return false;
            }
            throw new Win32Exception(error);
        }
    }

    // Starts a process fully detached from the caller: no console window, no inherited handles
    // (so the caller's console or pipes are never held open), its own process group and - where
    // the caller's job object allows it - outside that job, so closing a terminal does not kill it.
    public static class ProcessLauncher
    {
        private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
        private const uint CREATE_NO_WINDOW = 0x08000000;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
        private static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
            IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int StartDetached(string applicationPath, string commandLine, string workingDirectory, IDictionary environment)
        {
            IntPtr environmentBlock = Marshal.StringToHGlobalUni(BuildEnvironmentBlock(environment));
            try
            {
                uint flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP;
                int result = TryStart(applicationPath, commandLine, workingDirectory, environmentBlock, flags | CREATE_BREAKAWAY_FROM_JOB);
                if (result > 0)
                {
                    return result;
                }
                // Breakaway is not permitted by every job object; start inside the job instead.
                result = TryStart(applicationPath, commandLine, workingDirectory, environmentBlock, flags);
                if (result > 0)
                {
                    return result;
                }
                throw new Win32Exception(-result);
            }
            finally
            {
                Marshal.FreeHGlobal(environmentBlock);
            }
        }

        private static int TryStart(string applicationPath, string commandLine, string workingDirectory, IntPtr environmentBlock, uint flags)
        {
            STARTUPINFO startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            PROCESS_INFORMATION processInfo;
            // CreateProcess may modify the command line buffer, so it has to be writable.
            StringBuilder buffer = new StringBuilder(commandLine, commandLine.Length + 1);
            bool ok = CreateProcess(applicationPath, buffer, IntPtr.Zero, IntPtr.Zero, false, flags,
                environmentBlock, workingDirectory, ref startupInfo, out processInfo);
            if (!ok)
            {
                int error = Marshal.GetLastWin32Error();
                return error == 0 ? -1 : -error;
            }
            CloseHandle(processInfo.hThread);
            CloseHandle(processInfo.hProcess);
            return processInfo.dwProcessId;
        }

        private static string BuildEnvironmentBlock(IDictionary environment)
        {
            List<string> keys = new List<string>();
            foreach (object key in environment.Keys)
            {
                keys.Add(key.ToString());
            }
            keys.Sort(StringComparer.OrdinalIgnoreCase);
            StringBuilder block = new StringBuilder();
            foreach (string key in keys)
            {
                object value = environment[key];
                if (value == null || key.Length == 0 || key.IndexOf('=') > 0)
                {
                    continue;
                }
                block.Append(key).Append('=').Append(value.ToString()).Append('\0');
            }
            block.Append('\0');
            return block.ToString();
        }
    }

    // Status line of a long operation in the console window: the current step, a turning bar and the time the step
    // has taken so far. A timer redraws it four times a second, so it keeps moving while PowerShell waits for a
    // blocking call. It writes only into a real console window, never into redirected output. Everything else that
    // writes to the console removes it first (Clear).
    public static class StatusLine
    {
        private const int STD_OUTPUT_HANDLE = -11;
        private static readonly object Gate = new object();
        private static readonly string[] Bars = new string[] { "|", "/", "-", "\\" };
        private static System.Threading.Timer timer;
        private static System.Diagnostics.Stopwatch watch;
        private static string text;
        private static int frame;
        private static int length;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WriteConsoleW(IntPtr hConsoleOutput, string lpBuffer, int nNumberOfCharsToWrite, out int lpNumberOfCharsWritten, IntPtr lpReserved);

        public static bool Visible
        {
            get { lock (Gate) { return text != null; } }
        }

        public static void Show(string value)
        {
            lock (Gate)
            {
                text = value ?? string.Empty;
                watch = System.Diagnostics.Stopwatch.StartNew();
                frame = 0;
                Draw();
                if (timer == null)
                {
                    timer = new System.Threading.Timer(Tick, null, 250, 250);
                }
            }
        }

        public static void Clear()
        {
            lock (Gate)
            {
                if (timer != null)
                {
                    timer.Dispose();
                    timer = null;
                }
                if (text != null && length > 0)
                {
                    Write("\r" + new string(' ', length) + "\r", false);
                }
                text = null;
                length = 0;
            }
        }

        // "12 s" below a minute, "1:05 min" from a minute on.
        public static string FormatElapsed(TimeSpan elapsed)
        {
            int seconds = (int)Math.Floor(elapsed.TotalSeconds);
            if (seconds < 60)
            {
                return seconds.ToString(System.Globalization.CultureInfo.InvariantCulture) + " s";
            }
            return string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0}:{1:00} min", seconds / 60, seconds % 60);
        }

        // One frame: indentation, bar, text and - from the first second on - the time, cut to the window width.
        public static string Render(string value, int frameNumber, TimeSpan elapsed, int width)
        {
            string line = "  " + Bars[Math.Abs(frameNumber % Bars.Length)] + " " + value;
            if (elapsed.TotalSeconds >= 1)
            {
                line += " " + FormatElapsed(elapsed);
            }
            if (width > 1 && line.Length >= width)
            {
                line = line.Substring(0, width - 1);
            }
            return line;
        }

        private static void Tick(object state)
        {
            try
            {
                lock (Gate)
                {
                    if (text != null)
                    {
                        Draw();
                    }
                }
            }
            catch (Exception)
            {
                // A timer thread must never end the process.
            }
        }

        // Callers hold Gate.
        private static void Draw()
        {
            int width = 80;
            try
            {
                width = Console.WindowWidth;
            }
            catch (Exception)
            {
                width = 80;
            }
            string line = Render(text, frame, watch.Elapsed, width);
            frame++;
            string padding = new string(' ', Math.Max(0, length - line.Length));
            if (Write("\r" + line + padding, true))
            {
                length = line.Length;
            }
        }

        private static bool Write(string value, bool colored)
        {
            IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
            int mode;
            if (handle == IntPtr.Zero || handle == new IntPtr(-1) || !GetConsoleMode(handle, out mode))
            {
                return false;
            }
            ConsoleColor previous = ConsoleColor.Gray;
            bool recolored = false;
            try
            {
                if (colored)
                {
                    previous = Console.ForegroundColor;
                    Console.ForegroundColor = ConsoleColor.Cyan;
                    recolored = true;
                }
                int written;
                return WriteConsoleW(handle, value, value.Length, out written, IntPtr.Zero);
            }
            catch (Exception)
            {
                return false;
            }
            finally
            {
                if (recolored)
                {
                    try
                    {
                        Console.ForegroundColor = previous;
                    }
                    catch (Exception)
                    {
                        // The color stays; the next output sets its own.
                    }
                }
            }
        }
    }

    // The window CloudDrives runs in (menu, diagnosis): the CloudDrives symbol in the title bar and the taskbar, and
    // an identity of its own for the taskbar, so the window is not grouped with other console windows and pinning it
    // starts CloudDrives again. Only the classic console window can be changed; Windows Terminal owns its windows.
    public static class ConsoleWindow
    {
        private const int WM_SETICON = 0x0080;
        private const int ICON_SMALL = 0;
        private const int ICON_BIG = 1;
        private const uint IMAGE_ICON = 1;
        private const uint LR_LOADFROMFILE = 0x10;
        private const ushort VT_LPWSTR = 31;
        private static readonly Guid AppUserModelKeys = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey
        {
            public Guid FormatId;
            public uint PropertyId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PropVariant
        {
            public ushort Type;
            public ushort Reserved1;
            public ushort Reserved2;
            public ushort Reserved3;
            public IntPtr Value;
            public IntPtr Value2;
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            void GetCount(out uint count);
            void GetAt(uint index, out PropertyKey key);
            void GetValue(ref PropertyKey key, out PropVariant value);
            void SetValue(ref PropertyKey key, ref PropVariant value);
            void Commit();
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint load);

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        // False when there is no classic console window to change (Windows Terminal, hidden window).
        public static bool SetIdentity(string iconFile, string appId, string relaunchCommand, string displayName)
        {
            IntPtr window = GetConsoleWindow();
            if (window == IntPtr.Zero || !IsWindowVisible(window)) return false;
            // The icons stay loaded while the window exists; Windows only borrows them.
            IntPtr small = LoadImage(IntPtr.Zero, iconFile, IMAGE_ICON, 16, 16, LR_LOADFROMFILE);
            IntPtr big = LoadImage(IntPtr.Zero, iconFile, IMAGE_ICON, 32, 32, LR_LOADFROMFILE);
            if (small != IntPtr.Zero) SendMessage(window, WM_SETICON, (IntPtr)ICON_SMALL, small);
            if (big != IntPtr.Zero) SendMessage(window, WM_SETICON, (IntPtr)ICON_BIG, big);

            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            if (SHGetPropertyStoreForWindow(window, ref iid, out store) != 0 || store == null) return true;
            try
            {
                // The relaunch details first: the taskbar reads them when the identity is set.
                SetText(store, 2, relaunchCommand);  // System.AppUserModel.RelaunchCommand
                SetText(store, 3, iconFile + ",0");  // System.AppUserModel.RelaunchIconResource
                SetText(store, 4, displayName);      // System.AppUserModel.RelaunchDisplayNameResource
                SetText(store, 5, appId);            // System.AppUserModel.ID
                store.Commit();
            }
            finally
            {
                Marshal.ReleaseComObject(store);
            }
            return true;
        }

        private static void SetText(IPropertyStore store, uint id, string text)
        {
            PropertyKey key = new PropertyKey();
            key.FormatId = AppUserModelKeys;
            key.PropertyId = id;
            PropVariant value = new PropVariant();
            value.Type = VT_LPWSTR;
            value.Value = Marshal.StringToCoTaskMemUni(text);
            try
            {
                store.SetValue(ref key, ref value);
            }
            finally
            {
                Marshal.FreeCoTaskMem(value.Value);
            }
        }
    }
}

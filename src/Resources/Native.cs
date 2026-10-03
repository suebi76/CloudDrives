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
}

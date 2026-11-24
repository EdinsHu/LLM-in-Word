using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace WordMath.Windows;

// Protect the whole configuration so a stored key cannot be separated from its service URL.
internal sealed class ModelSecretStore(string path)
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob
    {
        public int Length;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy,
        IntPtr reserved, IntPtr options, uint flags, out Blob output);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr options, uint flags, out Blob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    // With no LOCAL_MACHINE flag, DPAPI binds the blob to the current Windows user.
    private static byte[] Transform(byte[] data, bool protect)
    {
        var pinned = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            var input = new Blob { Length = data.Length, Data = pinned.AddrOfPinnedObject() };
            Blob output;
            const uint noPrompt = 1;
            bool success = protect
                ? CryptProtectData(ref input, "WordMath", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, noPrompt, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, noPrompt, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var result = new byte[output.Length];
                Marshal.Copy(output.Data, result, 0, output.Length);
                if (!protect) Marshal.Copy(new byte[output.Length], 0, output.Data, output.Length);
                return result;
            }
            finally { LocalFree(output.Data); }
        }
        finally { pinned.Free(); }
    }

    public ModelConfiguration Read()
    {
        if (!File.Exists(path)) return new ModelConfiguration([], null);
        try
        {
            byte[] clear = Transform(File.ReadAllBytes(path), false);
            try
            {
                ModelConfiguration? saved = JsonSerializer.Deserialize<ModelConfiguration>(clear);
                if (saved?.Accounts is null) throw new InvalidDataException();
                return saved;
            }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Win32Exception or JsonException)
        {
            throw new InvalidOperationException("无法读取已有模型配置。请确认当前 Windows 用户可以访问 WordMath 配置文件。", exception);
        }
    }

    public void Write(ModelConfiguration state)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        byte[] clear = JsonSerializer.SerializeToUtf8Bytes(state);
        byte[] cipher;
        try { cipher = Transform(clear, true); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(cipher);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }
}

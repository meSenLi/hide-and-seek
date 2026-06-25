using System;
using System.Security.Cryptography;
using System.Text;

namespace HideAndSeek.Core.Util
{
    /// <summary>
    /// 加密工具 — 严格对齐服务端 skynet.crypt（lua-crypt.c）
    /// 
    /// DH 参数：P = 0xffffffffffffffc5（最大 64 位素数），G = 5，8 字节小端 uint64
    /// DES：8 字节密钥，ECB 模式，ISO 7816-4 填充
    /// HMAC：MD5 取前 8 字节
    /// Base64：标准编码
    /// </summary>
    public static class CryptoUtil
    {
        private const ulong DH_P = 0xffffffffffffffc5UL;
        private const ulong DH_G = 5;

        // ====== Base64 ======
        public static string Base64Encode(byte[] data) => Convert.ToBase64String(data);
        public static byte[] Base64Decode(string s) => Convert.FromBase64String(s);

        // ====== DH 密钥交换 ======

        public static byte[] DhRandomKey()
        {
            var key = new byte[8];
            using var rng = RandomNumberGenerator.Create();
            rng.GetBytes(key);
            if (BytesToU64LE(key) == 0) key[0] |= 1;
            return key;
        }

        /// <summary>pub = G^priv mod P</summary>
        public static byte[] DhExchange(byte[] privateKey8)
        {
            var priv = BytesToU64LE(privateKey8);
            return U64ToBytesLE(PowModP(DH_G, priv));
        }

        /// <summary>secret = peerPub^priv mod P</summary>
        public static byte[] DhSecret(byte[] peerPublicKey8, byte[] privateKey8)
        {
            var peerPub = BytesToU64LE(peerPublicKey8);
            var priv = BytesToU64LE(privateKey8);
            return U64ToBytesLE(PowModP(peerPub, priv));
        }

        private static ulong PowModP(ulong a, ulong b)
        {
            if (a > DH_P) a %= DH_P;
            if (b == 1) return a;
            var t = PowModP(a, b >> 1);
            t = MulModP(t, t);
            if ((b & 1) != 0) t = MulModP(t, a);
            return t;
        }

        private static ulong MulModP(ulong a, ulong b)
        {
            ulong m = 0;
            while (b != 0)
            {
                if ((b & 1) != 0)
                {
                    var t = DH_P - a;
                    if (m >= t) m -= t; else m += a;
                }
                if (a >= DH_P - a) a = a * 2 - DH_P; else a = a * 2;
                b >>= 1;
            }
            return m;
        }

        private static ulong BytesToU64LE(byte[] b)
        {
            ulong v = 0;
            for (int i = Math.Min(7, b.Length - 1); i >= 0; i--)
                v = (v << 8) | b[i];
            return v;
        }

        private static byte[] U64ToBytesLE(ulong v)
        {
            var b = new byte[8];
            for (int i = 0; i < 8; i++) { b[i] = (byte)(v & 0xFF); v >>= 8; }
            return b;
        }

        // ====== HMAC-MD5 (64-bit) ======
        public static byte[] Hmac64(byte[] data, byte[] key)
        {
            using var hmac = new HMACMD5(key);
            var hash = hmac.ComputeHash(data);
            var result = new byte[8];
            Buffer.BlockCopy(hash, 0, result, 0, 8);
            return result;
        }

        // ====== DES (8-byte key, ECB, ISO 7816-4 padding) ======
        public static byte[] DesEncode(byte[] key8, byte[] data)
        {
            int padLen = 8 - (data.Length % 8);
            var padded = new byte[data.Length + padLen];
            Buffer.BlockCopy(data, 0, padded, 0, data.Length);
            padded[data.Length] = 0x80;
            return DesEcbTransform(key8, padded, encrypt: true);
        }

        public static byte[] DesDecode(byte[] key8, byte[] encryptedData)
        {
            var decrypted = DesEcbTransform(key8, encryptedData, encrypt: false);
            int len = decrypted.Length;
            while (len > 0 && decrypted[len - 1] == 0x00) len--;
            if (len > 0 && decrypted[len - 1] == 0x80) len--;
            var result = new byte[len];
            Buffer.BlockCopy(decrypted, 0, result, 0, len);
            return result;
        }

        private static byte[] DesEcbTransform(byte[] key8, byte[] data, bool encrypt)
        {
            using var des = DES.Create();
            des.Mode = CipherMode.ECB;
            des.Padding = PaddingMode.None;
            des.Key = key8;
            using var t = encrypt ? des.CreateEncryptor() : des.CreateDecryptor();
            return t.TransformFinalBlock(data, 0, data.Length);
        }

        // ====== Token ======
        public static byte[] BuildToken(string user, string server, string password, bool isRegister)
        {
            var u = Base64Encode(Encoding.UTF8.GetBytes(user));
            var s = Base64Encode(Encoding.UTF8.GetBytes(server));
            var p = Base64Encode(Encoding.UTF8.GetBytes(password));
            return Encoding.UTF8.GetBytes(isRegister ? $"{u}@{s}:register:{p}" : $"{u}@{s}:{p}");
        }
    }
}

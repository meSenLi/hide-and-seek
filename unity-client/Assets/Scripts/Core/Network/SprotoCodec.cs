using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;

namespace HideAndSeek.Core.Network
{
    /// <summary>
    /// Sproto 二进制编解码器 — 对齐服务端 sproto 协议
    /// 
    /// 帧格式：[2字节大端长度][sproto body]
    /// 
    /// Sproto body 结构:
    ///   [varint: prototag] [message fields...] [package field type(0x00)] [package field session(0x08)]
    /// 
    /// prototag = tag * 2 + (has_response ? 1 : 0)  (请求)
    /// prototag = tag * 2                        (响应)
    /// 
    /// 协议 tag 来自 game.sproto / push.sproto:
    ///   rpc_heart_beat=1, rpc_ping=2, rpc_echo=3, rpc_get_user_info=4,
    ///   rpc_add_item=5, rpc_get_inventory=6, rpc_change_nickname=7, push=1
    /// </summary>
    public class SprotoCodec
    {
        private readonly Dictionary<string, int> _nameToTag = new();
        private readonly Dictionary<int, string> _tagToName = new();
        private readonly Dictionary<int, bool> _hasResponse = new();

        public SprotoCodec()
        {
            // game.sproto RPC 协议 (tag, has_response)
            Register("rpc_heart_beat", 1, true);
            Register("rpc_ping", 2, true);
            Register("rpc_echo", 3, true);
            Register("rpc_get_user_info", 4, true);
            Register("rpc_add_item", 5, true);
            Register("rpc_get_inventory", 6, true);
            Register("rpc_change_nickname", 7, true);

            // push.sproto (tag, no response)
            Register("push", 1, false);
        }

        public void Register(string name, int tag, bool hasResponse)
        {
            _nameToTag[name] = tag;
            _tagToName[tag] = name;
            _hasResponse[tag] = hasResponse;
        }

        // ====== 编码 ======

        /// <summary>编码 RPC 请求帧</summary>
        public byte[] EncodeRequest(string rpcName, Dictionary<string, object> args, int session)
        {
            if (!_nameToTag.TryGetValue(rpcName, out var tag))
                throw new ArgumentException($"Unknown RPC: {rpcName}");

            using var ms = new MemoryStream();

            // protocol tag (request: tag*2 + 1)
            WriteVarint(ms, (uint)(tag * 2 + 1));

            // message fields (hardcoded per RPC type)
            EncodeMessageFields(ms, rpcName, args);

            // package envelope: type=REQUEST(0), session
            WriteFieldVarint(ms, 0, 0);  // type
            WriteFieldVarint(ms, 1, (ulong)session);  // session

            return ms.ToArray();
        }

        /// <summary>编码 Push 帧（服务端→客户端用，实际客户端不编码 push）</summary>
        public byte[] EncodePush(string pushName, Dictionary<string, object> args)
        {
            if (!_nameToTag.TryGetValue(pushName, out var tag))
                throw new ArgumentException($"Unknown push: {pushName}");

            using var ms = new MemoryStream();
            WriteVarint(ms, (uint)(tag * 2));  // push: no response bit
            EncodePushFields(ms, pushName, args);
            WriteFieldVarint(ms, 0, 0);  // type=REQUEST
            WriteFieldVarint(ms, 1, 0);  // session=0 (push has no session)
            return ms.ToArray();
        }

        // ====== 解码 ======

        /// <summary>解码帧 → (isResponse, session, rpcName, fields)</summary>
        public (bool isResponse, int session, string name, Dictionary<string, object> fields) Decode(byte[] data)
        {
            using var ms = new MemoryStream(data);

            // read prototag
            var prototag = ReadVarint(ms);
            bool isResponse = (prototag & 1) == 0;
            int tag = (int)(prototag >> 1);

            string name = _tagToName.TryGetValue(tag, out var n) ? n : $"unknown_{tag}";
            var fields = DecodeMessageFields(ms, name, isResponse);

            // read package fields (type, session)
            int session = 0;
            while (ms.Position < ms.Length)
            {
                var ftag = ReadVarint(ms);
                int fieldNum = (int)(ftag >> 3);
                int wireType = (int)(ftag & 7);
                if (fieldNum == 0)
                    ReadVarint(ms); // type - ignore
                else if (fieldNum == 1)
                    session = (int)ReadVarint(ms);
                else
                    SkipField(ms, wireType);
            }

            return (isResponse, session, name, fields);
        }

        // ====== 字段编解码（按协议硬编码） ======

        private void EncodeMessageFields(MemoryStream ms, string rpcName, Dictionary<string, object> args)
        {
            args ??= new Dictionary<string, object>();
            switch (rpcName)
            {
                case "rpc_ping":
                    WriteFieldString(ms, 0, GetString(args, "msg", ""));
                    break;
                case "rpc_echo":
                    WriteFieldString(ms, 0, GetString(args, "content", ""));
                    break;
                case "rpc_add_item":
                    WriteFieldVarint(ms, 0, (ulong)GetInt(args, "id", 0));
                    WriteFieldString(ms, 1, GetString(args, "name", ""));
                    break;
                case "rpc_change_nickname":
                    WriteFieldString(ms, 0, GetString(args, "name", ""));
                    break;
                // rpc_heart_beat, rpc_get_user_info, rpc_get_inventory: no request fields
            }
        }

        private void EncodePushFields(MemoryStream ms, string name, Dictionary<string, object> args)
        {
            if (name == "push")
            {
                WriteFieldString(ms, 0, GetString(args, "channel", ""));
                WriteFieldString(ms, 1, GetString(args, "content", ""));
            }
        }

        private Dictionary<string, object> DecodeMessageFields(MemoryStream ms, string name, bool isResponse)
        {
            var fields = new Dictionary<string, object>();

            if (isResponse)
            {
                switch (name)
                {
                    case "rpc_heart_beat":
                        DecodeField(ms, fields, "time", 0, "int");
                        break;
                    case "rpc_ping":
                        DecodeField(ms, fields, "msg", 0, "string");
                        break;
                    case "rpc_echo":
                        DecodeField(ms, fields, "content", 0, "string");
                        break;
                    case "rpc_get_user_info":
                        DecodeField(ms, fields, "userid", 0, "string");
                        DecodeField(ms, fields, "subid", 1, "string");
                        DecodeField(ms, fields, "login_time", 2, "int");
                        break;
                    case "rpc_add_item":
                        DecodeField(ms, fields, "ok", 0, "int");
                        break;
                    case "rpc_get_inventory":
                        DecodeField(ms, fields, "count", 0, "int");
                        break;
                }
            }
            else
            {
                // push or server→client request
                if (name == "push")
                {
                    DecodeField(ms, fields, "channel", 0, "string");
                    DecodeField(ms, fields, "content", 1, "string");
                }
                else
                {
                    // unknown push → skip all fields until package envelope
                    // Package fields (type, session) have tag 0 and 1
                    while (ms.Position < ms.Length)
                    {
                        var ftag = ReadVarint(ms);
                        int fn = (int)(ftag >> 3);
                        int wt = (int)(ftag & 7);
                        if (fn <= 1) { ms.Position -= VarintSize(ftag); break; } // hit package field, rewind
                        SkipField(ms, wt);
                    }
                }
            }

            return fields;
        }

        // ====== Sproto 底层编码 ======

        private static void WriteFieldVarint(MemoryStream ms, int fieldNum, ulong value)
        {
            WriteVarint(ms, ((uint)fieldNum << 3) | 0);  // wire_type 0
            WriteVarint(ms, value);
        }

        private static void WriteFieldString(MemoryStream ms, int fieldNum, string value)
        {
            var bytes = Encoding.UTF8.GetBytes(value ?? "");
            WriteVarint(ms, ((uint)fieldNum << 3) | 2);  // wire_type 2
            WriteVarint(ms, (ulong)bytes.Length);
            ms.Write(bytes, 0, bytes.Length);
        }

        private static void WriteVarint(MemoryStream ms, ulong value)
        {
            while (value >= 0x80)
            {
                ms.WriteByte((byte)(value | 0x80));
                value >>= 7;
            }
            ms.WriteByte((byte)value);
        }

        private static ulong ReadVarint(MemoryStream ms)
        {
            ulong value = 0;
            int shift = 0;
            while (true)
            {
                int b = ms.ReadByte();
                if (b < 0) break;
                value |= (ulong)(b & 0x7F) << shift;
                if ((b & 0x80) == 0) break;
                shift += 7;
            }
            return value;
        }

        private static int VarintSize(ulong value)
        {
            int n = 1;
            while (value >= 0x80) { value >>= 7; n++; }
            return n;
        }

        private void DecodeField(MemoryStream ms, Dictionary<string, object> fields, string key, int expectedFieldNum, string type)
        {
            if (ms.Position >= ms.Length) return;
            var ftag = ReadVarint(ms);
            int fn = (int)(ftag >> 3);
            int wt = (int)(ftag & 7);

            if (fn == expectedFieldNum)
            {
                if (type == "int")
                    fields[key] = (long)ReadVarint(ms);
                else if (type == "string")
                {
                    int len = (int)ReadVarint(ms);
                    var buf = new byte[len];
                    ms.Read(buf, 0, len);
                    fields[key] = Encoding.UTF8.GetString(buf);
                }
            }
            else
            {
                // field number mismatch → skip, then peek next
                SkipField(ms, wt);
                DecodeField(ms, fields, key, expectedFieldNum, type);
            }
        }

        private static void SkipField(MemoryStream ms, int wireType)
        {
            if (wireType == 0) ReadVarint(ms);           // varint
            else if (wireType == 2)                      // length-delimited
            {
                int len = (int)ReadVarint(ms);
                ms.Seek(len, SeekOrigin.Current);
            }
        }

        // ====== helpers ======
        private static string GetString(Dictionary<string, object> d, string key, string def)
            => d.TryGetValue(key, out var v) ? v?.ToString() ?? def : def;

        private static int GetInt(Dictionary<string, object> d, string key, int def)
            => d.TryGetValue(key, out var v) && v != null ? Convert.ToInt32(v) : def;

        /// <summary>Serialize user data to sproto-compatible args dict</summary>
        public static Dictionary<string, object> ToArgs(object obj)
        {
            if (obj == null) return new Dictionary<string, object>();
            if (obj is Dictionary<string, object> d) return d;
            var result = new Dictionary<string, object>();
            foreach (var prop in obj.GetType().GetProperties())
                result[prop.Name] = prop.GetValue(obj);
            foreach (var field in obj.GetType().GetFields())
                result[field.Name] = field.GetValue(obj);
            return result;
        }
    }

    public enum SprotoMessageType { REQUEST = 0, RESPONSE = 1 }
}

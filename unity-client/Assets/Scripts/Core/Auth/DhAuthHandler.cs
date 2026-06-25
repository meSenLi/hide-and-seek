using System;
using System.Text;
using System.Threading.Tasks;
using HideAndSeek.Core.Network;
using HideAndSeek.Core.Util;
using UnityEngine;

namespace HideAndSeek.Core.Auth
{
    /// <summary>
    /// DH 鉴权握手 — 严格对齐服务端 account.lua + lua-crypt.c
    /// 
    /// 流程（7 步文本行协议）：
    ///   1. S→C: base64(8字节 challenge)
    ///   2. C→S: base64(client DH pub = G^priv mod P)
    ///   3. S→C: base64(server DH pub)
    ///   4. 双方计算 secret = DH-Secret(peerPub, priv)
    ///   5. C→S: base64(HMAC-MD5(challenge, secret)[:8])
    ///   6. C→S: base64(DES(secret, token))
    ///   7. S→C: "200 base64(subid)" 或错误码
    /// </summary>
    public class DhAuthHandler
    {
        private readonly TcpConnection _connection;
        private readonly string _serverName;

        public DhAuthHandler(TcpConnection connection, string serverName)
        {
            _connection = connection;
            _serverName = serverName;
        }

        public async Task<string> AuthenticateAsync(string username, string password, bool isRegister = false)
        {
            try
            {
                // Step 1: 接收 8 字节 challenge
                var challengeLine = await _connection.ReadLineAsync();
                var challenge = CryptoUtil.Base64Decode(challengeLine);
                Debug.Log($"[DhAuth] challenge received");

                // Step 2: 生成客户端密钥对，发送公钥
                var clientPriv = CryptoUtil.DhRandomKey();
                var clientPub = CryptoUtil.DhExchange(clientPriv);
                await _connection.SendLineAsync(CryptoUtil.Base64Encode(clientPub));

                // Step 3: 接收服务端公钥
                var serverPubLine = await _connection.ReadLineAsync();
                var serverPub = CryptoUtil.Base64Decode(serverPubLine);

                // Step 4: 计算共享密钥
                var secret = CryptoUtil.DhSecret(serverPub, clientPriv);

                // Step 5: 发送 HMAC(challenge, secret)
                var hmac = CryptoUtil.Hmac64(challenge, secret);
                await _connection.SendLineAsync(CryptoUtil.Base64Encode(hmac));

                // Step 6: 构造 token 并用 DES 加密发送
                var token = CryptoUtil.BuildToken(username, _serverName, password, isRegister);
                var encryptedToken = CryptoUtil.DesEncode(secret, token);
                await _connection.SendLineAsync(CryptoUtil.Base64Encode(encryptedToken));

                // Step 7: 接收结果
                var resultLine = await _connection.ReadLineAsync();
                Debug.Log($"[DhAuth] result: {resultLine}");

                if (resultLine.StartsWith("200 "))
                {
                    var subidBase64 = resultLine.Substring(4);
                    var subidBytes = CryptoUtil.Base64Decode(subidBase64);
                    var subid = Encoding.UTF8.GetString(subidBytes);
                    Debug.Log($"[DhAuth] success, subid={subid}");
                    return subid;
                }

                Debug.LogError($"[DhAuth] failed: {resultLine}");
                return null;
            }
            catch (Exception e)
            {
                Debug.LogError($"[DhAuth] exception: {e.Message}");
                return null;
            }
        }
    }
}


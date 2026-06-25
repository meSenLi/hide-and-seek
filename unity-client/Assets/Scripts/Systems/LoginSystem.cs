using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using HideAndSeek.Core.Auth;
using HideAndSeek.Core.Network;
using HideAndSeek.Core.Rpc;
using UnityEngine;

namespace HideAndSeek.Systems
{
    /// <summary>
    /// 登录系统 — DH 鉴权 + 登录/注册
    /// </summary>
    public class LoginSystem : BaseSystem
    {
        public string Username { get; private set; }
        public string Subid { get; private set; }
        public bool IsLoggedIn { get; private set; }

        public event Action OnLoginSuccess;
        public event Action<string> OnLoginFailed;
        public event Action<string> OnDisconnected;

        private TcpConnection _connection;
        private DhAuthHandler _authHandler;

        public void BindConnection(TcpConnection connection, string serverName)
        {
            _connection = connection;
            _authHandler = new DhAuthHandler(connection, serverName);
            connection.OnDisconnected += reason =>
            {
                IsLoggedIn = false;
                OnDisconnected?.Invoke(reason);
            };
        }

        public async Task<bool> LoginAsync(string username, string password)
        {
            if (_authHandler == null) { Debug.LogError("[Login] not bound"); return false; }
            var subid = await _authHandler.AuthenticateAsync(username, password, false);
            if (subid != null) { Username = username; Subid = subid; IsLoggedIn = true;
                _connection.OnAuthComplete(); Rpc.OnPush += OnServerPush; OnLoginSuccess?.Invoke(); return true; }
            OnLoginFailed?.Invoke("auth failed"); return false;
        }

        public async Task<bool> RegisterAsync(string username, string password)
        {
            if (_authHandler == null) { Debug.LogError("[Login] not bound"); return false; }
            var subid = await _authHandler.AuthenticateAsync(username, password, true);
            if (subid != null) { Username = username; Subid = subid; IsLoggedIn = true;
                _connection.OnAuthComplete(); Rpc.OnPush += OnServerPush; OnLoginSuccess?.Invoke(); return true; }
            OnLoginFailed?.Invoke("register failed"); return false;
        }

        private void OnServerPush(string channel, Dictionary<string, object> fields)
        {
            Debug.Log($"[Login] push: {channel} = {fields.GetValueOrDefault("content", "")}");
            PublishEvent("EVENT_PUSH", new { channel, content = fields.GetValueOrDefault("content", "") });
        }

        public override void Shutdown() { if (Rpc != null) Rpc.OnPush -= OnServerPush; base.Shutdown(); }
    }
}

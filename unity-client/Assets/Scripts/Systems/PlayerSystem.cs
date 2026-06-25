using System.Collections.Generic;
using System.Threading.Tasks;
using UnityEngine;

namespace HideAndSeek.Systems
{
    /// <summary>
    /// 玩家信息系统 — rpc_get_user_info, rpc_ping, rpc_echo, rpc_heart_beat, rpc_change_nickname
    /// </summary>
    public class PlayerSystem : BaseSystem
    {
        public string UserId { get; private set; }
        public string DisplayName { get; private set; }
        public long LoginTime { get; private set; }

        public async Task<bool> FetchUserInfoAsync()
        {
            try
            {
                var fields = await CallRpc("rpc_get_user_info");
                UserId = fields.TryGetValue("userid", out var uid) ? uid?.ToString() ?? "" : "";
                DisplayName = UserId;
                LoginTime = fields.TryGetValue("login_time", out var lt) ? (long)lt : 0;
                PublishEvent("EVENT_USER_INFO_READY");
                return true;
            }
            catch (System.Exception e) { Debug.LogError($"[Player] fetch info failed: {e.Message}"); return false; }
        }

        public async Task<bool> ChangeNicknameAsync(string name)
        {
            try
            {
                await CallRpc("rpc_change_nickname", new { name });
                DisplayName = name;
                PublishEvent("EVENT_NICKNAME_CHANGED", name);
                return true;
            }
            catch (System.Exception e) { Debug.LogError($"[Player] nickname failed: {e.Message}"); return false; }
        }

        public async Task<long> HeartbeatAsync()
        {
            try { var f = await CallRpc("rpc_heart_beat"); return f.TryGetValue("time", out var t) ? (long)t : 0; }
            catch { return 0; }
        }

        public async Task<string> PingAsync(string msg = "ping")
        {
            try { var f = await CallRpc("rpc_ping", new { msg }); return f.TryGetValue("msg", out var m) ? m?.ToString() : ""; }
            catch (System.Exception e) { Debug.LogError($"[Player] ping failed: {e.Message}"); return null; }
        }
    }
}

using System.Collections.Generic;
using System.Threading.Tasks;
using HideAndSeek.Core.Rpc;

namespace HideAndSeek.Systems
{
    public abstract class BaseSystem
    {
        public string SystemName => GetType().Name;
        protected RpcClient Rpc { get; private set; }
        protected EventBus Events { get; private set; }
        public bool IsInitialized { get; private set; }

        public virtual void Init(RpcClient rpc, EventBus events)
        {
            Rpc = rpc;
            Events = events;
            IsInitialized = true;
        }

        public virtual void InitFinish() { }
        public virtual void Shutdown() { IsInitialized = false; }

        /// <summary>发送 RPC 并返回原始字段字典</summary>
        protected async Task<Dictionary<string, object>> CallRpc(string rpcName, object args = null, int timeoutMs = 5000)
            => await Rpc.CallAsync(rpcName, args, timeoutMs);

        /// <summary>RPC 通知（不等响应）</summary>
        protected async Task NotifyRpc(string rpcName, object args = null)
            => await Rpc.NotifyAsync(rpcName, args);

        protected void PublishEvent(string name, object data = null) => Events?.Publish(name, data);
        protected void SubscribeEvent(string name, System.Action<object> h) => Events?.Subscribe(name, h);
    }
}

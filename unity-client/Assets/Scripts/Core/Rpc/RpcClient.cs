using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using HideAndSeek.Core.Network;
using UnityEngine;

namespace HideAndSeek.Core.Rpc
{
    /// <summary>
    /// RPC 客户端 — 与服务端 session.lua 对齐
    /// 
    /// 调用 CallAsync(name, args) → 编码 sproto 请求 → 等待响应
    /// Push 通过 OnPush 事件分发
    /// </summary>
    public class RpcClient : IDisposable
    {
        private readonly TcpConnection _connection;
        private readonly SprotoCodec _codec;

        private int _sessionCounter;
        private readonly Dictionary<int, TaskCompletionSource<Dictionary<string, object>>> _pending = new();
        private readonly object _lock = new();

        public event Action<string, Dictionary<string, object>> OnPush;

        public RpcClient(TcpConnection connection, SprotoCodec codec)
        {
            _connection = connection;
            _codec = codec;
            _connection.OnFrameReceived += HandleFrame;
        }

        public async Task<Dictionary<string, object>> CallAsync(string rpcName, object args = null, int timeoutMs = 5000)
        {
            _sessionCounter++;
            var session = _sessionCounter;
            var tcs = new TaskCompletionSource<Dictionary<string, object>>();
            lock (_lock) { _pending[session] = tcs; }

            var argsDict = SprotoCodec.ToArgs(args);
            var body = _codec.EncodeRequest(rpcName, argsDict, session);
            await _connection.SendFrameAsync(body);

            var completed = await Task.WhenAny(tcs.Task, Task.Delay(timeoutMs));
            if (completed != tcs.Task)
            {
                lock (_lock) { _pending.Remove(session); }
                throw new TimeoutException($"RPC [{rpcName}] timeout ({timeoutMs}ms)");
            }

            return await tcs.Task;
        }

        public async Task NotifyAsync(string rpcName, object args = null)
        {
            _sessionCounter++;
            var argsDict = SprotoCodec.ToArgs(args);
            var body = _codec.EncodeRequest(rpcName, argsDict, _sessionCounter);
            await _connection.SendFrameAsync(body);
        }

        private void HandleFrame(byte[] frame)
        {
            try
            {
                var (isResponse, session, name, fields) = _codec.Decode(frame);

                if (isResponse)
                {
                    lock (_lock)
                    {
                        if (_pending.TryGetValue(session, out var tcs))
                        {
                            _pending.Remove(session);
                            tcs.TrySetResult(fields);
                        }
                    }
                }
                else
                {
                    // Push from server
                    UnityMainThreadDispatcher.Util.UnityMainThreadDispatcher.Instance?.Enqueue(
                        () => OnPush?.Invoke(name, fields));
                }
            }
            catch (Exception e)
            {
                Debug.LogError($"[RpcClient] frame error: {e.Message}");
            }
        }

        public void Dispose()
        {
            _connection.OnFrameReceived -= HandleFrame;
            lock (_lock)
            {
                foreach (var kv in _pending) kv.Value.TrySetCanceled();
                _pending.Clear();
            }
        }
    }
}


using System;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;

namespace HideAndSeek.Core.Network
{
    /// <summary>
    /// TCP 连接管理 — 帧收发（鉴权文本行 + 业务 2 字节大端长度帧）
    /// </summary>
    public class TcpConnection : IDisposable
    {
        public enum State { Disconnected, Connecting, Authing, Connected }
        public State CurrentState { get; private set; } = State.Disconnected;

        public event Action<byte[]> OnFrameReceived;
        public event Action<string> OnDisconnected;

        private TcpClient _client;
        private NetworkStream _stream;
        private CancellationTokenSource _cts;
        private byte[] _recvBuf = new byte[8192];
        private readonly ByteBuffer _buffer = new();

        public async Task<bool> ConnectAsync(string host, int port, int timeoutMs = 5000)
        {
            CurrentState = State.Connecting;
            try
            {
                _client = new TcpClient { NoDelay = true };
                using var cts = new CancellationTokenSource(timeoutMs);
                await _client.ConnectAsync(host, port).WaitAsync(cts.Token);
                _stream = _client.GetStream();
                _cts = new CancellationTokenSource();
                CurrentState = State.Authing;
                _ = ReceiveLoopAsync(_cts.Token);
                Debug.Log($"[Tcp] connected {host}:{port}");
                return true;
            }
            catch (Exception e) { Disconnect($"connect failed: {e.Message}"); return false; }
        }

        public async Task SendLineAsync(string line)
        {
            var data = Encoding.UTF8.GetBytes(line + "\n");
            await _stream.WriteAsync(data, 0, data.Length);
            await _stream.FlushAsync();
        }

        public async Task<string> ReadLineAsync(int timeoutMs = 5000)
        {
            var tcs = new TaskCompletionSource<string>();
            using var cts = new CancellationTokenSource(timeoutMs);
            cts.Token.Register(() => tcs.TrySetException(new TimeoutException("ReadLine timeout")));

            Action<byte[]> original = OnFrameReceived;
            OnFrameReceived = frame =>
            {
                var text = Encoding.UTF8.GetString(frame);
                OnFrameReceived = original;
                tcs.TrySetResult(text);
            };
            return await tcs.Task;
        }

        public async Task SendFrameAsync(byte[] data)
        {
            var len = (ushort)data.Length;
            var frame = new byte[2 + data.Length];
            frame[0] = (byte)(len >> 8);
            frame[1] = (byte)(len & 0xFF);
            Buffer.BlockCopy(data, 0, frame, 2, data.Length);
            await _stream.WriteAsync(frame, 0, frame.Length);
            await _stream.FlushAsync();
        }

        public void OnAuthComplete()
        {
            CurrentState = State.Connected;
            _buffer.Clear();
            Debug.Log("[Tcp] auth complete, binary mode");
        }

        private async Task ReceiveLoopAsync(CancellationToken ct)
        {
            try
            {
                while (!ct.IsCancellationRequested && _client?.Connected == true)
                {
                    int n = await _stream.ReadAsync(_recvBuf, 0, _recvBuf.Length, ct);
                    if (n == 0) { Disconnect("server closed"); return; }
                    _buffer.Write(_recvBuf, 0, n);

                    if (CurrentState == State.Authing)
                    {
                        while (_buffer.TryReadLine(out var line))
                            EnqueueFrame(Encoding.UTF8.GetBytes(line));
                    }
                    else
                    {
                        while (_buffer.TryReadFrame(out var frame))
                            EnqueueFrame(frame);
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Disconnect($"recv error: {e.Message}"); }
        }

        private void EnqueueFrame(byte[] frame)
        {
            UnityMainThreadDispatcher.Util.UnityMainThreadDispatcher.Instance?.Enqueue(
                () => OnFrameReceived?.Invoke(frame));
        }

        private void Disconnect(string reason)
        {
            if (CurrentState == State.Disconnected) return;
            CurrentState = State.Disconnected;
            _cts?.Cancel();
            _stream?.Close();
            _client?.Close();
            Debug.LogWarning($"[Tcp] disconnected: {reason}");
            UnityMainThreadDispatcher.Util.UnityMainThreadDispatcher.Instance?.Enqueue(
                () => OnDisconnected?.Invoke(reason));
        }

        public void Dispose()
        {
            Disconnect("disposed");
            _cts?.Dispose();
            _client?.Dispose();
        }
    }

    /// <summary>字节缓冲区：支持按行 / 按帧读取</summary>
    internal class ByteBuffer
    {
        private byte[] _buf = new byte[65536];
        private int _rp, _wp;

        public void Write(byte[] data, int off, int len)
        {
            if (_wp + len > _buf.Length) Compact();
            if (_wp + len > _buf.Length) Array.Resize(ref _buf, Math.Max(_buf.Length * 2, _wp + len));
            Buffer.BlockCopy(data, off, _buf, _wp, len);
            _wp += len;
        }

        public void Clear() { _rp = _wp = 0; }

        public bool TryReadLine(out string line)
        {
            line = null;
            for (int i = _rp; i < _wp; i++)
            {
                if (_buf[i] == '\n')
                {
                    int len = i - _rp;
                    if (len > 0 && _buf[i - 1] == '\r') len--;
                    line = Encoding.UTF8.GetString(_buf, _rp, len);
                    _rp = i + 1;
                    return true;
                }
            }
            return false;
        }

        public bool TryReadFrame(out byte[] frame)
        {
            frame = null;
            int avail = _wp - _rp;
            if (avail < 2) return false;
            int len = (_buf[_rp] << 8) | _buf[_rp + 1];
            if (avail < 2 + len) return false;
            frame = new byte[len];
            Buffer.BlockCopy(_buf, _rp + 2, frame, 0, len);
            _rp += 2 + len;
            return true;
        }

        private void Compact()
        {
            if (_rp > 0) { int n = _wp - _rp; Buffer.BlockCopy(_buf, _rp, _buf, 0, n); _rp = 0; _wp = n; }
        }
    }

    /// <summary>Task 扩展方法</summary>
    internal static class TaskExtensions
    {
        public static async Task<T> WaitAsync<T>(this Task<T> task, CancellationToken ct)
        {
            var tcs = new TaskCompletionSource<bool>();
            using (ct.Register(s => ((TaskCompletionSource<bool>)s).TrySetResult(true), tcs))
            {
                if (task != await Task.WhenAny(task, tcs.Task))
                    throw new OperationCanceledException(ct);
            }
            return await task;
        }
    }
}

// Re-export for convenience
namespace HideAndSeek.Core.Util { public class UnityMainThreadDispatcher : UnityEngine.MonoBehaviour
{
    public static UnityMainThreadDispatcher Instance { get; private set; }
    private readonly System.Collections.Generic.Queue<Action> _q = new();
    private readonly object _lock = new();
    void Awake() { if (Instance) { Destroy(gameObject); return; } Instance = this; DontDestroyOnLoad(gameObject); }
    void Update() { lock (_lock) while (_q.Count > 0) _q.Dequeue()?.Invoke(); }
    public void Enqueue(Action a) { lock (_lock) _q.Enqueue(a); }
}}

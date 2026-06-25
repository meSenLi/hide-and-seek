using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using HideAndSeek.Core.Network;
using HideAndSeek.Core.Rpc;
using HideAndSeek.Core.Util;
using HideAndSeek.Systems;
using UnityEngine;

namespace HideAndSeek.Game
{
    /// <summary>
    /// 游戏管理器 — Unity 客户端入口（单例）
    /// 生命周期: Boot → Connect → Auth → LoggedIn
    /// </summary>
    public class GameManager : MonoBehaviour
    {
        public static GameManager Instance { get; private set; }

        [Header("Server")]
        [SerializeField] private string _serverHost = "127.0.0.1";
        [SerializeField] private int _serverPort = 8888;
        [SerializeField] private string _serverName = "hideandseek";

        [Header("Debug")]
        [SerializeField] private bool _autoConnect;
        [SerializeField] private string _debugUser = "";
        [SerializeField] private string _debugPass = "";

        // ====== Core ======
        public TcpConnection Connection { get; private set; }
        public SprotoCodec Codec { get; private set; }
        public RpcClient Rpc { get; private set; }
        public EventBus Events { get; private set; }

        // ====== Systems ======
        public LoginSystem Login { get; private set; }
        public PlayerSystem Player { get; private set; }
        public InventorySystem Inventory { get; private set; }

        private readonly List<BaseSystem> _allSystems = new();

        public enum ClientState { Boot, Connecting, Authing, LoggedIn, Disconnected }
        public ClientState State { get; private set; } = ClientState.Boot;
        public event Action<ClientState, ClientState> OnStateChanged;

        private void Awake()
        {
            if (Instance) { Destroy(gameObject); return; }
            Instance = this;
            DontDestroyOnLoad(gameObject);

            if (!FindObjectOfType<UnityMainThreadDispatcher>())
                new GameObject("MainThreadDispatcher").AddComponent<UnityMainThreadDispatcher>();

            InitCore();
            InitSystems();
        }

        private void Start()
        {
            if (_autoConnect && !string.IsNullOrEmpty(_debugUser))
                _ = ConnectAndLoginAsync(_debugUser, _debugPass);
        }

        private void InitCore()
        {
            Connection = new TcpConnection();
            Codec = new SprotoCodec();
            Rpc = new RpcClient(Connection, Codec);
            Events = new EventBus();
            Connection.OnDisconnected += OnNetworkDisconnected;
            Rpc.OnPush += OnServerPush;
        }

        private void InitSystems()
        {
            Login = new LoginSystem();
            Player = new PlayerSystem();
            Inventory = new InventorySystem();

            RegisterSystem(Login);
            RegisterSystem(Player);
            RegisterSystem(Inventory);

            Login.BindConnection(Connection, _serverName);

            foreach (var sys in _allSystems) sys.Init(Rpc, Events);
            foreach (var sys in _allSystems) sys.InitFinish();

            Login.OnLoginSuccess += async () =>
            {
                await Player.FetchUserInfoAsync();
                await Inventory.FetchInventoryAsync();
            };
            Login.OnLoginFailed += reason => Debug.LogError($"Login failed: {reason}");
            Login.OnDisconnected += reason => Debug.LogWarning($"Disconnected: {reason}");
        }

        private void RegisterSystem(BaseSystem sys) => _allSystems.Add(sys);

        // ====== Public API ======

        public async Task<bool> ConnectAndLoginAsync(string user, string pass, bool register = false)
        {
            SetState(ClientState.Connecting);
            if (!await Connection.ConnectAsync(_serverHost, _serverPort))
            { SetState(ClientState.Disconnected); return false; }

            SetState(ClientState.Authing);
            bool ok = register ? await Login.RegisterAsync(user, pass) : await Login.LoginAsync(user, pass);
            SetState(ok ? ClientState.LoggedIn : ClientState.Disconnected);
            return ok;
        }

        public void Disconnect()
        {
            Connection?.Dispose();
            SetState(ClientState.Disconnected);
        }

        // ====== Internal ======

        private void OnNetworkDisconnected(string reason)
        {
            SetState(ClientState.Disconnected);
            Events.Publish("EVENT_DISCONNECTED", reason);
        }

        private void OnServerPush(string channel, Dictionary<string, object> fields)
        {
            Events.Publish("EVENT_SERVER_PUSH", new { channel, fields });
        }

        private void SetState(ClientState s)
        {
            if (State == s) return;
            var old = State; State = s;
            Debug.Log($"[Game] {old} → {s}");
            OnStateChanged?.Invoke(old, s);
        }

        private void OnDestroy()
        {
            foreach (var sys in _allSystems) sys.Shutdown();
            _allSystems.Clear();
            Rpc?.Dispose();
            Connection?.Dispose();
        }

        // ====== Editor debug ======
#if UNITY_EDITOR
        [ContextMenu("Connect & Login")]
        private async void DebugConnect()
        {
            var u = string.IsNullOrEmpty(_debugUser) ? "guest" + UnityEngine.Random.Range(100000, 999999) : _debugUser;
            var p = string.IsNullOrEmpty(_debugPass) ? UnityEngine.Random.Range(100000, 999999).ToString() : _debugPass;
            await ConnectAndLoginAsync(u, p, true);
        }

        [ContextMenu("Disconnect")]
        private void DebugDisconnect() => Disconnect();
#endif
    }
}


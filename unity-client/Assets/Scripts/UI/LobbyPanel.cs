using HideAndSeek.Game;
using UnityEngine;
using UnityEngine.UI;

namespace HideAndSeek.UI
{
    /// <summary>
    /// 大厅面板 — 登录成功后的主界面
    /// </summary>
    public class LobbyPanel : BasePanel
    {
        [Header("UI 组件")]
        [SerializeField] private Text _welcomeText;
        [SerializeField] private Text _playerInfoText;
        [SerializeField] private Button _startGameButton;
        [SerializeField] private Button _inventoryButton;
        [SerializeField] private Button _disconnectButton;
        [SerializeField] private InputField _chatInput;
        [SerializeField] private Button _sendButton;
        [SerializeField] private Text _chatLog;

        private GameManager _gm;

        public override void OnOpen()
        {
            _gm = GameManager.Instance;
            _welcomeText.text = $"欢迎, {_gm.Login.Username}!";
            _playerInfoText.text = $"UID: {_gm.Login.Username} | SubID: {_gm.Login.Subid}";

            _startGameButton.onClick.AddListener(OnStartGame);
            _inventoryButton.onClick.AddListener(OnOpenInventory);
            _disconnectButton.onClick.AddListener(OnDisconnect);
            _sendButton.onClick.AddListener(OnSendChat);

            // 拉取数据
            _ = RefreshAsync();
        }

        public override void OnClose()
        {
            _startGameButton.onClick.RemoveAllListeners();
            _inventoryButton.onClick.RemoveAllListeners();
            _disconnectButton.onClick.RemoveAllListeners();
            _sendButton.onClick.RemoveAllListeners();
        }

        private async System.Threading.Tasks.Task RefreshAsync()
        {
            await _gm.Player.FetchUserInfoAsync();
            await _gm.Inventory.FetchInventoryAsync();

            _playerInfoText.text = $"UID: {_gm.Player.UserId} | 物品: {_gm.Inventory.ItemCount}";
        }

        private void OnStartGame()
        {
            Debug.Log("[LobbyPanel] 开始游戏");
            // TODO: 进入游戏场景
        }

        private void OnOpenInventory()
        {
            Debug.Log("[LobbyPanel] 打开背包");
            AppendChat("背包: 还没有物品，输入 add_item 测试");
        }

        private void OnDisconnect()
        {
            _gm.Disconnect();
            UIManager.Instance.ClosePanel<LobbyPanel>();
            UIManager.Instance.OpenPanel<LoginPanel>();
        }

        private async void OnSendChat()
        {
            var text = _chatInput.text.Trim();
            if (string.IsNullOrEmpty(text)) return;

            _chatInput.text = "";

            if (text.StartsWith("ping"))
            {
                var msg = text.Length > 4 ? text.Substring(5) : "ping";
                var resp = await _gm.Player.PingAsync(msg);
                AppendChat($"Ping 响应: {resp}");
            }
            else if (text == "info")
            {
                await _gm.Player.FetchUserInfoAsync();
                AppendChat($"用户: {_gm.Player.UserId}");
            }
            else if (text == "inv" || text == "inventory")
            {
                await _gm.Inventory.FetchInventoryAsync();
                AppendChat($"背包物品数: {_gm.Inventory.ItemCount}");
            }
            else if (text.StartsWith("add "))
            {
                var name = text.Substring(4);
                var ok = await _gm.Inventory.AddItemAsync(UnityEngine.Random.Range(1, 1000), name);
                AppendChat(ok ? $"添加物品: {name}" : "添加失败");
            }
            else if (text == "hb" || text == "heartbeat")
            {
                var t = await _gm.Player.HeartbeatAsync();
                AppendChat($"心跳: {t}");
            }
            else if (text == "help")
            {
                AppendChat("命令: ping [msg] | info | inv | add <name> | hb | help");
            }
            else
            {
                AppendChat($"发送: {text}");
            }
        }

        private void AppendChat(string msg)
        {
            if (_chatLog != null)
                _chatLog.text += $"\n{msg}";
        }
    }
}

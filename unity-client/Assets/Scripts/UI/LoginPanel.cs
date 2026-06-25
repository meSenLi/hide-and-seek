using HideAndSeek.Game;
using UnityEngine;
using UnityEngine.UI;

namespace HideAndSeek.UI
{
    /// <summary>
    /// 登录面板 — 用户名/密码输入 + 登录/注册按钮
    /// </summary>
    public class LoginPanel : BasePanel
    {
        [Header("UI 组件")]
        [SerializeField] private InputField _usernameInput;
        [SerializeField] private InputField _passwordInput;
        [SerializeField] private Button _loginButton;
        [SerializeField] private Button _registerButton;
        [SerializeField] private Text _statusText;
        [SerializeField] private GameObject _loadingMask;

        private void Start()
        {
            _loginButton.onClick.AddListener(OnLoginClicked);
            _registerButton.onClick.AddListener(OnRegisterClicked);

            GameManager.Instance.OnStateChanged += OnGameStateChanged;
        }

        private void OnDestroy()
        {
            if (GameManager.Instance != null)
                GameManager.Instance.OnStateChanged -= OnGameStateChanged;
        }

        private async void OnLoginClicked()
        {
            var user = _usernameInput.text.Trim();
            var pass = _passwordInput.text;

            if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(pass))
            {
                SetStatus("请输入用户名和密码", Color.red);
                return;
            }

            SetLoading(true);
            SetStatus("正在登录...", Color.yellow);

            var success = await GameManager.Instance.ConnectAndLoginAsync(user, pass, false);

            if (!success)
            {
                SetStatus("登录失败，请检查网络或账号密码", Color.red);
                SetLoading(false);
            }
        }

        private async void OnRegisterClicked()
        {
            var user = _usernameInput.text.Trim();
            var pass = _passwordInput.text;

            if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(pass))
            {
                SetStatus("请输入用户名和密码", Color.red);
                return;
            }

            SetLoading(true);
            SetStatus("正在注册...", Color.yellow);

            var success = await GameManager.Instance.ConnectAndLoginAsync(user, pass, true);

            if (!success)
            {
                SetStatus("注册失败，请重试", Color.red);
                SetLoading(false);
            }
        }

        private void OnGameStateChanged(GameManager.ClientState oldState, GameManager.ClientState newState)
        {
            switch (newState)
            {
                case GameManager.ClientState.LoggedIn:
                    SetStatus("登录成功!", Color.green);
                    SetLoading(false);
                    // 切换到大厅面板
                    UIManager.Instance?.ClosePanel<LoginPanel>();
                    UIManager.Instance?.OpenPanel<LobbyPanel>();
                    break;
                case GameManager.ClientState.Disconnected:
                    if (oldState != GameManager.ClientState.Boot)
                    {
                        SetStatus("连接断开", Color.red);
                        SetLoading(false);
                    }
                    break;
            }
        }

        private void SetStatus(string msg, Color color)
        {
            if (_statusText != null)
            {
                _statusText.text = msg;
                _statusText.color = color;
            }
        }

        private void SetLoading(bool loading)
        {
            if (_loadingMask != null)
                _loadingMask.SetActive(loading);
            _loginButton.interactable = !loading;
            _registerButton.interactable = !loading;
        }
    }
}

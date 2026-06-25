using UnityEngine;
using UnityEngine.UI;

namespace HideAndSeek.UI
{
    /// <summary>
    /// 游戏内 HUD — 显示玩家状态、计时器、道具栏等
    /// </summary>
    public class GameHudPanel : BasePanel
    {
        [Header("HUD 组件")]
        [SerializeField] private Text _timerText;
        [SerializeField] private Text _roleText;         // "寻找者" / "躲藏者"
        [SerializeField] private Text _scoreText;
        [SerializeField] private Transform _skillSlotRoot;
        [SerializeField] private Button _exitButton;

        // 躲猫猫核心状态
        private float _roundTime;
        private bool _isSeeker;

        public override void OnOpen()
        {
            _exitButton.onClick.AddListener(OnExitGame);
        }

        public override void OnClose()
        {
            _exitButton.onClick.RemoveAllListeners();
        }

        private void Update()
        {
            // 更新倒计时
            if (_roundTime > 0)
            {
                _roundTime -= Time.deltaTime;
                var mins = Mathf.FloorToInt(_roundTime / 60);
                var secs = Mathf.FloorToInt(_roundTime % 60);
                _timerText.text = $"{mins:00}:{secs:00}";
            }
        }

        /// <summary>
        /// 设置回合信息
        /// </summary>
        public void SetRoundInfo(float totalTime, bool isSeeker)
        {
            _roundTime = totalTime;
            _isSeeker = isSeeker;
            _roleText.text = isSeeker ? "寻找者" : "躲藏者";
            _roleText.color = isSeeker ? Color.red : Color.green;
        }

        public void SetScore(int score)
        {
            _scoreText.text = $"得分: {score}";
        }

        private void OnExitGame()
        {
            // 返回大厅
            UIManager.Instance.ClosePanel<GameHudPanel>();
            UIManager.Instance.OpenPanel<LobbyPanel>();
        }
    }
}

using System;
using System.Collections.Generic;
using UnityEngine;

namespace HideAndSeek.Game.GameMode
{
    /// <summary>
    /// 躲猫猫游戏模式 — 管理回合流程、角色分配、胜负判定
    /// 
    /// 对应后端游戏核心循环
    /// </summary>
    public class HideAndSeekMode : MonoBehaviour
    {
        public enum Phase
        {
            Waiting,        // 等待玩家
            Preparing,      // 准备阶段（倒计时）
            Hiding,         // 躲藏阶段（躲藏者找地方藏）
            Seeking,        // 寻找阶段（寻找者抓人）
            Result,         // 结算
        }

        public enum PlayerRole
        {
            Spectator,      // 观战
            Hider,          // 躲藏者
            Seeker,         // 寻找者
        }

        [Header("游戏参数")]
        [SerializeField] private float _prepareTime = 10f;
        [SerializeField] private float _hideTime = 5f;
        [SerializeField] private float _seekTime = 120f;
        [SerializeField] private int _minPlayers = 2;
        [SerializeField] private int _maxSeekers = 1;

        public Phase CurrentPhase { get; private set; } = Phase.Waiting;
        public PlayerRole MyRole { get; private set; } = PlayerRole.Spectator;

        private float _phaseTimer;
        private int _score;

        public event Action<Phase> OnPhaseChanged;
        public event Action<PlayerRole> OnRoleAssigned;
        public event Action<int> OnScoreChanged;

        private void Update()
        {
            if (CurrentPhase == Phase.Waiting) return;

            _phaseTimer -= Time.deltaTime;
            if (_phaseTimer <= 0)
            {
                AdvancePhase();
            }
        }

        /// <summary>
        /// 推进到下一阶段
        /// </summary>
        private void AdvancePhase()
        {
            switch (CurrentPhase)
            {
                case Phase.Preparing:
                    SetPhase(Phase.Hiding, _hideTime);
                    break;
                case Phase.Hiding:
                    SetPhase(Phase.Seeking, _seekTime);
                    break;
                case Phase.Seeking:
                    SetPhase(Phase.Result, 10f);
                    break;
                case Phase.Result:
                    // TODO: 回到等待或重新准备
                    SetPhase(Phase.Preparing, _prepareTime);
                    break;
            }
        }

        private void SetPhase(Phase phase, float duration)
        {
            CurrentPhase = phase;
            _phaseTimer = duration;
            Debug.Log($"[HideAndSeek] 阶段切换: {phase} (持续 {duration}s)");
            OnPhaseChanged?.Invoke(phase);
        }

        /// <summary>
        /// 分配角色（服务端下发）
        /// </summary>
        public void AssignRole(PlayerRole role)
        {
            MyRole = role;
            OnRoleAssigned?.Invoke(role);
        }

        /// <summary>
        /// 加分
        /// </summary>
        public void AddScore(int points)
        {
            _score += points;
            OnScoreChanged?.Invoke(_score);
        }

        /// <summary>
        /// 开始游戏（由服务端触发）
        /// </summary>
        public void StartGame()
        {
            _score = 0;
            SetPhase(Phase.Preparing, _prepareTime);
        }

        /// <summary>
        /// 获取当前阶段剩余时间
        /// </summary>
        public float GetRemainingTime() => _phaseTimer;
    }
}

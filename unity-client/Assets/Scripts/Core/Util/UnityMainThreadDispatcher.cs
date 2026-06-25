using System;
using System.Collections.Generic;
using UnityEngine;

namespace HideAndSeek.Core.Util
{
    /// <summary>
    /// Unity 主线程调度器 — 将回调 marshalling 到主线程执行
    /// 用法：在 Boot 场景中挂到 GameObject 上
    /// </summary>
    public class UnityMainThreadDispatcher : MonoBehaviour
    {
        public static UnityMainThreadDispatcher Instance { get; private set; }

        private readonly Queue<Action> _actions = new Queue<Action>();
        private readonly object _lock = new object();

        private void Awake()
        {
            if (Instance != null)
            {
                Destroy(gameObject);
                return;
            }
            Instance = this;
            DontDestroyOnLoad(gameObject);
        }

        private void Update()
        {
            lock (_lock)
            {
                while (_actions.Count > 0)
                {
                    _actions.Dequeue()?.Invoke();
                }
            }
        }

        public void Enqueue(Action action)
        {
            lock (_lock)
            {
                _actions.Enqueue(action);
            }
        }
    }
}

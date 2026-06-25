using System;
using System.Collections.Generic;
using UnityEngine;

namespace HideAndSeek.UI
{
    /// <summary>
    /// UI 管理器 — 管理所有 UI 面板的打开/关闭/栈
    /// </summary>
    public class UIManager : MonoBehaviour
    {
        public static UIManager Instance { get; private set; }

        [SerializeField] private Transform _panelRoot;

        private readonly Dictionary<Type, BasePanel> _panels = new();
        private readonly Stack<BasePanel> _panelStack = new();

        private void Awake()
        {
            if (Instance != null) { Destroy(gameObject); return; }
            Instance = this;
            DontDestroyOnLoad(gameObject);
        }

        /// <summary>
        /// 注册面板
        /// </summary>
        public void RegisterPanel<T>(T panel) where T : BasePanel
        {
            _panels[typeof(T)] = panel;
            panel.gameObject.SetActive(false);
        }

        /// <summary>
        /// 打开面板
        /// </summary>
        public T OpenPanel<T>() where T : BasePanel
        {
            if (_panels.TryGetValue(typeof(T), out var panel))
            {
                panel.gameObject.SetActive(true);
                panel.OnOpen();
                _panelStack.Push(panel);
                return panel as T;
            }
            Debug.LogError($"[UIManager] 未找到面板: {typeof(T).Name}");
            return null;
        }

        /// <summary>
        /// 关闭面板
        /// </summary>
        public void ClosePanel<T>() where T : BasePanel
        {
            if (_panels.TryGetValue(typeof(T), out var panel))
            {
                panel.OnClose();
                panel.gameObject.SetActive(false);
            }
        }

        /// <summary>
        /// 关闭当前顶部面板
        /// </summary>
        public void CloseTopPanel()
        {
            if (_panelStack.Count > 0)
            {
                var panel = _panelStack.Pop();
                panel.OnClose();
                panel.gameObject.SetActive(false);
            }
        }

        /// <summary>
        /// 关闭所有面板
        /// </summary>
        public void CloseAll()
        {
            while (_panelStack.Count > 0)
            {
                var panel = _panelStack.Pop();
                panel.OnClose();
                panel.gameObject.SetActive(false);
            }
        }
    }

    /// <summary>
    /// UI 面板基类
    /// </summary>
    public abstract class BasePanel : MonoBehaviour
    {
        public virtual void OnOpen() { }
        public virtual void OnClose() { }
    }
}

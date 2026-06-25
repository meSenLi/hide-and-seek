using System;
using System.Collections.Generic;
using UnityEngine;

namespace HideAndSeek.Systems
{
    /// <summary>
    /// 事件总线 — 系统间解耦通信
    /// 对应后端 events.lua
    /// </summary>
    public class EventBus
    {
        private readonly Dictionary<string, List<Action<object>>> _handlers = new();

        /// <summary>
        /// 订阅事件
        /// </summary>
        public void Subscribe(string eventName, Action<object> handler)
        {
            if (!_handlers.TryGetValue(eventName, out var list))
            {
                list = new List<Action<object>>();
                _handlers[eventName] = list;
            }
            list.Add(handler);
        }

        /// <summary>
        /// 取消订阅
        /// </summary>
        public void Unsubscribe(string eventName, Action<object> handler)
        {
            if (_handlers.TryGetValue(eventName, out var list))
            {
                list.Remove(handler);
            }
        }

        /// <summary>
        /// 发布事件
        /// </summary>
        public void Publish(string eventName, object data = null)
        {
            if (_handlers.TryGetValue(eventName, out var list))
            {
                foreach (var handler in list)
                {
                    try { handler?.Invoke(data); }
                    catch (Exception e) { Debug.LogError($"[EventBus] {eventName} 处理异常: {e.Message}"); }
                }
            }
        }

        /// <summary>
        /// 清除所有订阅
        /// </summary>
        public void Clear()
        {
            _handlers.Clear();
        }
    }
}

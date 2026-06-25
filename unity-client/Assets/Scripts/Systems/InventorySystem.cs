using System.Collections.Generic;
using System.Threading.Tasks;
using UnityEngine;

namespace HideAndSeek.Systems
{
    /// <summary>
    /// 背包系统 — rpc_get_inventory, rpc_add_item
    /// </summary>
    public class InventorySystem : BaseSystem
    {
        public List<ItemData> Items { get; private set; } = new();
        public int ItemCount => Items.Count;

        public class ItemData { public int id; public string name; }

        public async Task<bool> FetchInventoryAsync()
        {
            try
            {
                var f = await CallRpc("rpc_get_inventory");
                Debug.Log($"[Inventory] count={f.GetValueOrDefault("count", 0)}");
                PublishEvent("EVENT_INVENTORY_READY");
                return true;
            }
            catch (System.Exception e) { Debug.LogError($"[Inventory] fetch failed: {e.Message}"); return false; }
        }

        public async Task<bool> AddItemAsync(int id, string name)
        {
            try
            {
                var f = await CallRpc("rpc_add_item", new { id, name });
                if (f.TryGetValue("ok", out var ok) && (long)ok == 1)
                {
                    Items.Add(new ItemData { id = id, name = name });
                    PublishEvent("EVENT_ITEM_ADDED", new ItemData { id = id, name = name });
                    return true;
                }
                return false;
            }
            catch (System.Exception e) { Debug.LogError($"[Inventory] add failed: {e.Message}"); return false; }
        }
    }
}

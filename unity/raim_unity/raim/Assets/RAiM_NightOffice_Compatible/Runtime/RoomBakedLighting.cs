using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

namespace RAiM.NightOffice.Compatible {
    // Prefabs do not serialize the scene's lightmap table. Register only this
    // room's maps, leaving every existing table entry and renderer untouched.
    [ExecuteAlways, DisallowMultipleComponent]
    public sealed class RoomBakedLighting : MonoBehaviour {
        [Serializable] public sealed class Map { public Texture2D color, direction, shadowMask; }
        [Serializable] public sealed class Binding {
            public Renderer renderer;
            public int map = -1;
            public Vector4 scaleOffset;
            public float[] sphericalHarmonics = new float[27];
        }
        public Map[] maps = Array.Empty<Map>();
        public Binding[] bindings = Array.Empty<Binding>();
        public LightmapsMode mode = LightmapsMode.CombinedDirectional;
        readonly List<Texture2D> held = new List<Texture2D>();
        sealed class Lease { public int users; public bool appended; }
        static readonly Dictionary<Texture2D, Lease> leases = new Dictionary<Texture2D, Lease>();
        static LightmapsMode previousMode;
        static bool changedMode;

        void OnEnable() { Apply(); }
        void OnDisable() { Release(); }
        [ContextMenu("Apply room lighting")]
        public void Apply() {
            if (!gameObject.scene.IsValid() || maps.Length == 0 || held.Count != 0) return;
            var table = new List<LightmapData>(LightmapSettings.lightmaps);
            if (table.Count == 0 && leases.Count == 0) {
                previousMode = LightmapSettings.lightmapsMode;
                changedMode = false;
                if (previousMode != mode) {
                    // iOS など、書き出し先によってはこの方式が使えず例外になる。
                    // 以前はここで止まり、部屋の光の焼き込みが一切当たっていなかった。
                    // 方式は変えずに、焼き込み自体は続けて当てる。
                    try { LightmapSettings.lightmapsMode = mode; changedMode = true; }
                    catch (ArgumentException e) {
                        Debug.LogWarning($"[RoomBakedLighting] lightmapsMode={mode} は使えないため {previousMode} のまま当てます: {e.Message}");
                    }
                }
            }
            var indices = new int[maps.Length];
            for (int i = 0; i < maps.Length; i++) {
                var map = maps[i];
                if (!map.color) { indices[i] = -1; continue; }
                int index = table.FindIndex(m => m.lightmapColor == map.color && m.lightmapDir == map.direction && m.shadowMask == map.shadowMask);
                bool appended = index < 0;
                if (appended) {
                    index = table.Count;
                    table.Add(new LightmapData { lightmapColor = map.color, lightmapDir = map.direction, shadowMask = map.shadowMask });
                }
                if (!leases.TryGetValue(map.color, out var lease)) {
                    lease = new Lease { appended = appended }; leases.Add(map.color, lease);
                }
                lease.users++; held.Add(map.color); indices[i] = index;
            }
            LightmapSettings.lightmaps = table.ToArray();
            foreach (var binding in bindings) {
                if (!binding.renderer) continue;
                binding.renderer.lightmapIndex = binding.map >= 0 && binding.map < indices.Length ? indices[binding.map] : -1;
                binding.renderer.lightmapScaleOffset = binding.scaleOffset;
                if (binding.sphericalHarmonics == null || binding.sphericalHarmonics.Length != 27) continue;
                var sh = new SphericalHarmonicsL2();
                for (int rgb = 0; rgb < 3; rgb++) for (int n = 0; n < 9; n++) sh[rgb,n] = binding.sphericalHarmonics[rgb * 9 + n];
                var block = new MaterialPropertyBlock();binding.renderer.GetPropertyBlock(block);
                block.CopySHCoefficientArraysFrom(new[] { sh });binding.renderer.SetPropertyBlock(block);
                binding.renderer.lightProbeUsage = LightProbeUsage.CustomProvided;
            }
        }
        public void Release() {
            if (held.Count == 0) return;
            foreach (var binding in bindings) if (binding.renderer) binding.renderer.lightmapIndex = -1;
            foreach (var texture in held) if (texture && leases.TryGetValue(texture, out var lease)) lease.users--;
            held.Clear();
            // Never compact another scene's indices. Only release our unused tail.
            var table = new List<LightmapData>(LightmapSettings.lightmaps);
            while (table.Count > 0) {
                var texture = table[table.Count - 1].lightmapColor;
                if (!texture || !leases.TryGetValue(texture, out var lease) || !lease.appended || lease.users != 0) break;
                int tail = table.Count - 1;bool usedElsewhere = false;
                foreach (var r in UnityEngine.Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include, FindObjectsSortMode.None))
                    if (r.lightmapIndex == tail && !r.transform.IsChildOf(transform)) { usedElsewhere = true;break; }
                if (usedElsewhere) break;
                table.RemoveAt(tail);leases.Remove(texture);
            }
            LightmapSettings.lightmaps = table.ToArray();
            if (table.Count == 0 && changedMode) { LightmapSettings.lightmapsMode = previousMode;changedMode = false; }
            var remove = new List<Texture2D>();
            foreach (var item in leases) if (item.Value.users == 0 &&
                (!item.Value.appended || !table.Exists(m => m.lightmapColor == item.Key))) remove.Add(item.Key);
            foreach (var key in remove) leases.Remove(key);
        }
    }
}

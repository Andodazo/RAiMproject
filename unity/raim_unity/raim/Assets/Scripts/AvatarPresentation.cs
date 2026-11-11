using System;
using RAiM.Companion;
using UnityEngine;

namespace RAiM.Presentation
{
    public enum AvatarMode { TwoD, ThreeD }

    // Selection and geometry only. Emotion/state delivery stays with the receiver.
    [DefaultExecutionOrder(-10000), DisallowMultipleComponent]
    public sealed class AvatarPresentation : MonoBehaviour
    {
        [SerializeField] SpriteRenderer spriteRenderer;
        [SerializeField] CompanionActor companion;
        Transform head;
        Renderer[] initializingRenderers;
        bool[] initializingEnabled;
        public AvatarMode RequestedMode { get; private set; } = AvatarMode.ThreeD;
        public AvatarMode ActiveMode { get; private set; } = AvatarMode.ThreeD;
        public event Action Changed;

        public void RequestMode(AvatarMode mode)
        {
            if (mode == AvatarMode.TwoD || mode == AvatarMode.ThreeD) RequestedMode = mode;
        }

        void Update()
        {
            if (!spriteRenderer || !companion) return;
            if (RequestedMode == ActiveMode) { RestoreInitializingRenderers(); return; }
            // Keep Awake/Start running during the first initialization, even when
            // Flutter has already selected 2D. Later public receive calls remain
            // usable while the initialized model root is inactive.
            if (!companion.Ready) {
                if (RequestedMode == AvatarMode.TwoD && initializingRenderers == null) {
                    initializingRenderers = companion.GetComponentsInChildren<Renderer>(true);
                    initializingEnabled = new bool[initializingRenderers.Length];
                    for (int i = 0; i < initializingRenderers.Length; i++) {
                        initializingEnabled[i] = initializingRenderers[i].enabled;
                        initializingRenderers[i].enabled = false;
                    }
                }
                return;
            }
            bool show3D = RequestedMode == AvatarMode.ThreeD;
            companion.gameObject.SetActive(show3D);
            spriteRenderer.enabled = !show3D;
            RestoreInitializingRenderers();
            ActiveMode = RequestedMode;
            Changed?.Invoke();
        }

        void RestoreInitializingRenderers()
        {
            if (initializingRenderers == null) return;
            for (int i = 0; i < initializingRenderers.Length; i++)
                if (initializingRenderers[i]) initializingRenderers[i].enabled = initializingEnabled[i];
            initializingRenderers = null;
            initializingEnabled = null;
        }

        public bool TryGetWorldBounds(out Bounds bounds)
        {
            bounds = default;
            if (ActiveMode == AvatarMode.TwoD) {
                if (!spriteRenderer || !spriteRenderer.sprite) return false;
                bounds = spriteRenderer.bounds;
                return true;
            }
            if (!companion || !companion.Ready || !companion.gameObject.activeInHierarchy) return false;
            bounds = companion.ModelBounds;
            return true;
        }

        public bool TryGetSpeechAnchor(out Vector3 position)
        {
            position = default;
            if (ActiveMode == AvatarMode.TwoD) {
                if (!spriteRenderer) return false;
                position = spriteRenderer.transform.position;
                return true;
            }
            if (!companion || !companion.Ready) return false;
            if (!head && !companion.model.TryGetBoneTransform(HumanBodyBones.Head, out head)) return false;
            position = head.position;
            return true;
        }

        void OnDestroy() { RestoreInitializingRenderers(); }
    }
}

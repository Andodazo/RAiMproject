using System;
using UnityEngine;

namespace RAiM.Companion
{
    [Serializable] public class PerformancePhrase
    {
        public string key;
        public AnimationClip clip;
        public float readableTime = 2;
        public float minimumInterval = 12;
        [TextArea] public string intention;
    }
    [CreateAssetMenu(menuName="RAiM/Performance library")]
    public sealed class PerformanceLibrary : ScriptableObject
    {
        [Tooltip("Match main's standing portraits: hold the dominant emotion pose and use the phone while a tool is active.")]
        public bool standingPortraitMode;
        [Range(.25f, 1.5f)] public float portraitPlaybackSpeed = 1;
        [Range(.2f, 2)] public float portraitTransitionSeconds = .43f;
        [Range(.2f, 2)] public float portraitContactReleaseSeconds = .4f;
        public AnimationClip[] idles;
        public AnimationClip talk;
        [Tooltip("Subtle additive breathing loop, played independently of the selected portrait.")]
        public AnimationClip breathing;
        [Tooltip("Offline/sleeping portrait motion; falls back to neutral when absent.")]
        public AnimationClip sleeping;
        public PerformancePhrase[] phrases;
        // Entries with the same fixed key are alternate performances, played in order.
        public PerformancePhrase Find(string key, int variant = 0)
        {
            var matches = Array.FindAll(phrases ?? Array.Empty<PerformancePhrase>(), p => p != null && p.key == key && p.clip != null);
            return matches.Length == 0 ? null : matches[Math.Max(0, variant) % matches.Length];
        }
    }
}

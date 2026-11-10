using System;
using UnityEngine;

namespace RAiM.Companion
{
    public enum FaceRegion { Brow, Eye, Mouth }
    [Serializable] public class ShapeContribution
    {
        public string shape;
        public FaceRegion region;
        [Range(0, 1)] public float amount;
        public ShapeContribution(string shape, FaceRegion region, float amount) { this.shape = shape; this.region = region; this.amount = amount; }
    }
    [Serializable] public class EmotionPose
    {
        public string key;
        public ShapeContribution[] shapes = Array.Empty<ShapeContribution>();
        public Vector3 headDegrees, chestDegrees;
        public Vector2 gaze;
        public Vector3 leftHandOffset, rightHandOffset;
        [Range(0,1)] public float fingerCurl;
        [TextArea] public string approximation;
    }
    [CreateAssetMenu(menuName = "RAiM/Companion emotion profile")]
    public class EmotionProfile : ScriptableObject
    {
        public string sourceSha256;
        public EmotionPose[] emotions = new EmotionPose[12];
        [Range(0.1f, 20)] public float smoothing = 7;
        [Range(0, 1)] public float browBudget = 0.85f, eyeBudget = 0.7f, mouthBudget = 0.65f;
        [Range(1, 10)] public float blinkInterval = 4.2f;
        [Tooltip("Both zero retain a fixed interval. Otherwise these bound the randomized onset-to-onset interval in seconds.")]
        [Min(0)] public float blinkIntervalMin, blinkIntervalMax;
        [Range(0.1f, 0.4f)] public float blinkDuration = 0.16f;
        [Range(0, 120)] public float neutralTimeout = 45;
        [Range(2, 30)] public float gestureInterval = 8;
        [Range(0, 1)] public float gestureStrength = 0.6f;
        [Range(0.5f, 2.5f)] public float faceGain = 1;
        [Range(0, 2)] public float bodyGain = 1;
        public bool comicMarks = true;
        [Range(.1f, .4f)] public float comicSize = .23f;
        [Range(1, 5)] public float comicDuration = 2.8f;
        public bool fullBodyActing;
        [Range(0, 1.5f)] public float stepGain = 1;
        [Range(0, 1.5f)] public float fingerActivity = 1;
        public Vector3 chinContactLocal = new Vector3(.012f, -.034f, .083f);

        public float NaturalBlink(float seconds)
        {
            return BlinkEnvelope(Mathf.Repeat(seconds, Mathf.Max(1, blinkInterval)), blinkDuration);
        }

        public static float BlinkEnvelope(float elapsed, float blinkDuration)
        {
            // Close, briefly touch, then reopen more slowly. Both ends have zero
            // velocity, and the eyelids stay fully open between complete blinks.
            float duration = Mathf.Clamp(blinkDuration, .1f, .4f);
            if (elapsed < 0 || elapsed >= duration) return 0;
            float t = elapsed / duration;
            if (t < .35f) return Mathf.SmoothStep(0, 1, t / .35f);
            if (t < .45f) return 1;
            return 1 - Mathf.SmoothStep(0, 1, (t - .45f) / .55f);
        }
    }
}

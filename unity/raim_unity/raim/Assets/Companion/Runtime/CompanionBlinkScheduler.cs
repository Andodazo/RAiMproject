using System;
using UnityEngine;

namespace RAiM.Companion
{
    // Schedule complete blinks; never randomize their weight on individual frames.
    public sealed class CompanionBlinkScheduler
    {
        readonly System.Random random;
        bool enabledLastTick, blinking;
        float waiting, elapsed, duration, nextInterval;
        public float Value { get; private set; }

        public CompanionBlinkScheduler(int seed) { random = new System.Random(seed); }

        public static float SampleInterval(EmotionProfile profile, System.Random random)
        {
            float center = Mathf.Max(1, profile.blinkInterval);
            if (profile.blinkIntervalMin <= 0 && profile.blinkIntervalMax <= 0) return center;
            float min = Mathf.Max(1, profile.blinkIntervalMin);
            float max = Mathf.Max(min, profile.blinkIntervalMax);
            if (max == min) return min;
            center = Mathf.Clamp(center, min, max);
            // A bounded log-normal draw favors ordinary pauses with occasional
            // longer gaps. The bounds and spread are artistic tuning, not a
            // physiological fit for this character. Do not touch Unity Random.
            const double spread = .38;
            double logMean = Math.Log(center) - spread * spread / 2;
            for (int attempt = 0; attempt < 64; attempt++)
            {
                double z = Math.Sqrt(-2 * Math.Log(1 - random.NextDouble()))
                    * Math.Cos(2 * Math.PI * random.NextDouble());
                float sample = (float)Math.Exp(logMean + spread * z);
                if (sample >= min && sample <= max) return sample;
            }
            return center;
        }

        public void Tick(EmotionProfile profile, float deltaTime, bool enabled)
        {
            if (!enabled)
            {
                enabledLastTick = blinking = false;
                Value = 0;
                return;
            }
            if (!enabledLastTick)
            {
                waiting = SampleInterval(profile, random);
                enabledLastTick = true;
            }
            float dt = Mathf.Clamp(deltaTime, 0, .1f);
            if (blinking)
            {
                elapsed += dt;
                Value = EmotionProfile.BlinkEnvelope(elapsed, duration);
                if (elapsed >= duration)
                {
                    blinking = false;
                    waiting = Mathf.Max(0, nextInterval - elapsed);
                    Value = 0;
                }
            }
            else
            {
                waiting -= dt;
                Value = 0;
                if (waiting <= 0)
                {
                    // Start at the beginning of the curve even after a slow frame.
                    // This also preserves a fully closed sample at 30 fps.
                    blinking = true;
                    elapsed = 0;
                    duration = Mathf.Clamp(profile.blinkDuration, .1f, .4f);
                    nextInterval = SampleInterval(profile, random);
                }
            }
        }
    }
}

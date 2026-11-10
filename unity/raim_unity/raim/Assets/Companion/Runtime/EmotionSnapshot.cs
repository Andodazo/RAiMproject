using System;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace RAiM.Companion
{
    // Wire contract: a complete weight snapshot, never a delta.
    public sealed class EmotionSnapshot
    {
        public static readonly string[] Keys = { "neutral", "happy", "sad", "angry", "surprised", "caring", "embarrassed", "excited", "curious", "amused", "thoughtful", "playful" };
        public readonly float[] Raw;
        public readonly float[] Normalized;
        public readonly float[] Effective;
        public readonly float Intensity;
        public EmotionSnapshot(float[] raw, float intensity)
        {
            Raw = (float[])raw.Clone(); Normalized = new float[12]; Effective = new float[12];
            Intensity = intensity;
            float sum = 0;
            for (int i = 0; i < 12; i++) sum += Raw[i];
            if (sum <= 0) { Normalized[0] = Effective[0] = 1; return; }
            float active = 0;
            for (int i = 0; i < 12; i++)
            {
                Normalized[i] = Raw[i] / sum;
                if (i > 0) active += Effective[i] = Intensity * Normalized[i];
            }
            Effective[0] = Math.Max(0, 1 - active);
        }
        public static EmotionSnapshot Neutral => new EmotionSnapshot(new float[12], 0.5f);
        public static bool Number(JToken token, out float value)
        {
            value = 0;
            if (token == null || (token.Type != JTokenType.Float && token.Type != JTokenType.Integer)) return false;
            double n = token.Value<double>();
            if (double.IsNaN(n) || double.IsInfinity(n)) return false;
            value = (float)Math.Max(0, Math.Min(1, n)); return true;
        }
        public static bool TryParse(string json, out EmotionSnapshot result)
        {
            result = null;
            if (string.IsNullOrWhiteSpace(json) || json.Length > 65536) return false;
            try
            {
                using (var reader = new JsonTextReader(new System.IO.StringReader(json)) { MaxDepth = 16, DateParseHandling = DateParseHandling.None })
                {
                    var obj = JObject.Load(reader, new JsonLoadSettings { DuplicatePropertyNameHandling = DuplicatePropertyNameHandling.Error });
                    if (reader.Read()) return false;
                    return TryParse(obj, out result);
                }
            }
            catch (Exception e) when (e is JsonException || e is ArgumentException || e is OverflowException) { return false; }
        }
        public static bool TryParse(JObject obj, out EmotionSnapshot result)
        {
            result = null;
            var raw = new float[12];
            JToken strength = obj["overall_intensity"] ?? obj["intensity"];
            float g = 0.5f;
            if (strength != null && !Number(strength, out g)) return false;
            if (obj["emotions"] is JObject weights)
            {
                bool known = !weights.HasValues;
                for (int i = 0; i < Keys.Length; i++)
                {
                    var v = weights[Keys[i]];
                    if (v == null) continue;
                    if (!Number(v, out raw[i])) return false;
                    known = true;
                }
                if (!known) return false; // unknown-only is not a neutral reset
            }
            else
            {
                if (obj["emotions"] != null) return false;
                if (obj["emotion"]?.Type != JTokenType.String) return false;
                int index = Array.IndexOf(Keys, obj["emotion"].Value<string>());
                if (index < 0) return false;
                raw[index] = 1; // legacy intensity is applied exactly once
            }
            result = new EmotionSnapshot(raw, g); return true;
        }
    }
}

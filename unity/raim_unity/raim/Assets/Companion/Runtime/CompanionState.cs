using System;
using Newtonsoft.Json.Linq;

namespace RAiM.Companion
{
    public enum BehaviorState { Idle, Listening, Thinking, Researching, Speaking }

    // Full local snapshot. The server does NOT supply these generation/sequence fields.
    public sealed class CompanionState
    {
        public long Generation { get; private set; } = -1;
        public long Sequence { get; private set; } = -1;
        public bool Listening, Thinking, ExternalWork, Playing;
        public float Amplitude;
        public string AudioSource = "none";
        public string AudioChunkId, RequestId;
        public BehaviorState Background => ExternalWork ? BehaviorState.Researching : Thinking ? BehaviorState.Thinking : Listening ? BehaviorState.Listening : BehaviorState.Idle;
        public BehaviorState Current => Playing ? BehaviorState.Speaking : Background;
        public bool TryApply(string json)
        {
            if (string.IsNullOrEmpty(json) || json.Length > 8192) return false;
            try
            {
                var j = JObject.Parse(json);
                if (j["generation"]?.Type != JTokenType.Integer || j["sequence"]?.Type != JTokenType.Integer) return false;
                long generation = j["generation"].Value<long>(), sequence = j["sequence"].Value<long>();
                if (generation < 0 || sequence < 0 || generation < Generation || (generation == Generation && sequence <= Sequence)) return false;
                foreach (string key in new[] { "listening", "thinking", "external_work", "playing" })
                    if (j[key]?.Type != JTokenType.Boolean) return false;
                float amplitude = 0;
                if (j["amplitude"] != null && !EmotionSnapshot.Number(j["amplitude"], out amplitude)) return false;
                Generation = generation; Sequence = sequence;
                Listening = j["listening"].Value<bool>(); Thinking = j["thinking"].Value<bool>();
                ExternalWork = j["external_work"].Value<bool>(); Playing = j["playing"].Value<bool>();
                Amplitude = Playing ? amplitude : 0;
                AudioSource = j["audio_source"]?.Type == JTokenType.String ? j["audio_source"].Value<string>() : "none";
                AudioChunkId = j["audio_chunk_id"]?.Type == JTokenType.String ? j["audio_chunk_id"].Value<string>() : null;
                RequestId = j["request_id"]?.Type == JTokenType.String ? j["request_id"].Value<string>() : null;
                return true;
            }
            catch (Exception e) when (e is Newtonsoft.Json.JsonException || e is OverflowException || e is ArgumentException) { return false; }
        }
        public void ClearActivity() { Listening = Thinking = ExternalWork = Playing = false; Amplitude = 0; }
        // New transport session: allow a freshly launched Flutter's local counters.
        public void ResetTransport() { Generation = Sequence = -1; ClearActivity(); }
    }
}

using UnityEngine;

namespace RAiM.NightOffice.Compatible
{
    /// <summary>A replaceable background receives local time as a fraction of one day.</summary>
    public interface ITimeOfDayBackgroundTarget
    {
        void ApplyTimeOfDay(float dayFraction, float unscaledDeltaTime, bool immediate);
    }

    [DefaultExecutionOrder(-90), DisallowMultipleComponent]
    public sealed class DeviceTimeOfDayDriver : MonoBehaviour
    {
        [Tooltip("Component implementing ITimeOfDayBackgroundTarget. The clock does not depend on its visuals.")]
        [SerializeField] private MonoBehaviour backgroundTarget;

        private ITimeOfDayBackgroundTarget target;

        private void Awake()
        {
            target = backgroundTarget as ITimeOfDayBackgroundTarget;
            if (target == null)
                Debug.LogError("Time of day background target is missing or incompatible.", this);
        }

        private void OnEnable()
        {
            // RoomContent may be activated after the Flutter clock has already synced.
            Apply(0f, true);
        }

        private void Update()
        {
            Apply(Time.unscaledDeltaTime, false);
        }

        private void Apply(float deltaTime, bool immediate)
        {
            if (target == null) return;
            var now = DeviceClock.DeviceNow;
            if (!now.HasValue) return; // Keep the authored night scene until the first sync.

            var seconds = now.Value.TimeOfDay.TotalSeconds;
            target.ApplyTimeOfDay((float)(seconds / 86400d), deltaTime, immediate);
        }
    }
}

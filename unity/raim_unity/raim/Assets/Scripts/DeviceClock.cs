using System;
using UnityEngine;

/// <summary>
/// Flutterから同期した端末時刻を、Unity内で共有する時計。
/// Syncと各プロパティは、Unityのメインスレッドから使用する。
/// </summary>
public static class DeviceClock
{
    // 最後に同期した日時。初回同期前はnull。
    public static DateTimeOffset? LastDeviceTime { get; private set; }

    private static double _receivedAtRealtime;

    // 参照されたときだけ実経過時間を加える。timeScaleが0でも時計は進む。
    public static DateTimeOffset? DeviceNow =>
        LastDeviceTime?.AddSeconds(
            Time.realtimeSinceStartupAsDouble - _receivedAtRealtime);

    public static void Sync(long unixMs, int utcOffsetMinutes)
    {
        // 変換が成功するまで、直前の正常な同期値は書き換えない。
        var deviceTime = DateTimeOffset
            .FromUnixTimeMilliseconds(unixMs)
            .ToOffset(TimeSpan.FromMinutes(utcOffsetMinutes));
        var receivedAt = Time.realtimeSinceStartupAsDouble;

        LastDeviceTime = deviceTime;
        _receivedAtRealtime = receivedAt;
    }

    // Domain Reloadを無効にしたEditorでも、次のPlayへ値を持ち越さない。
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
    private static void ResetState()
    {
        LastDeviceTime = null;
        _receivedAtRealtime = 0d;
    }
}

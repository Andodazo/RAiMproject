using System;
using UnityEngine;
namespace RAiM.Companion
{
    [Serializable] public class ComicAccentArt { public string key; public Mesh fill, outline; public Material color, border; }
    [CreateAssetMenu(menuName="RAiM/Comic accent library")]
    public sealed class ComicAccentLibrary : ScriptableObject { public ComicAccentArt[] marks; }
}

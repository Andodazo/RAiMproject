using System;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

namespace RAiM.Companion
{
    // Keep main's selected portrait until another emotion, tool or sleep event.
    // Optional idle accents are played only while the selected portrait is neutral.
    public sealed class StandingPortraitPlayer : IDisposable
    {
        static readonly int[] MainPriority = {1,2,3,4,0,9,5,8,6,7,11,10};
        const int PhoneSlot = 12, SleepSlot = 13, FirstIdleSlot = 14;
        readonly PlayableGraph graph;
        readonly AnimationMixerPlayable mixer;
        readonly AnimationClipPlayable breathing;
        readonly float breathingLength;
        readonly AnimationClipPlayable[] clips;
        readonly AnimationClip[] sources;
        readonly float[] lengths, weights, idleTimes;
        readonly System.Random idleRandom;
        readonly string neutralName;
        readonly float playbackSpeed, transitionSeconds, contactReleaseSeconds;
        int target, previousTarget, idleSlot = -1, lastIdleSlot = -1;
        float clock, releaseTime, idleElapsed, nextIdleAfter, breathingClock;
        public string Active => target == SleepSlot ? "sleeping" : target == PhoneSlot ? "researching_state" : EmotionSnapshot.Keys[Mathf.Clamp(target,0,11)];
        public string ActiveMotion => sources[idleSlot >= FirstIdleSlot ? idleSlot : target].name;
        public float Phase => idleSlot >= FirstIdleSlot ? idleTimes[idleSlot-FirstIdleSlot]/lengths[idleSlot] : (clock%lengths[target])/lengths[target];
        public float PhoneWeight => weights[PhoneSlot];

        public StandingPortraitPlayer(Animator animator, PerformanceLibrary library, int? seed = null)
        {
            if (library.idles == null || library.idles.Length == 0 || library.idles[0] == null)
                throw new InvalidOperationException("Standing portrait neutral clip is missing");
            int extraIdles = Math.Max(0, library.idles.Length-1);
            clips = new AnimationClipPlayable[FirstIdleSlot+extraIdles];
            sources = new AnimationClip[clips.Length]; lengths = new float[clips.Length]; weights = new float[clips.Length];
            idleTimes = new float[extraIdles];
            idleRandom = new System.Random(seed ?? Guid.NewGuid().GetHashCode());
            nextIdleAfter = NextIdleDelay();
            graph = PlayableGraph.Create("RAiM main standing portraits");
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            mixer = AnimationMixerPlayable.Create(graph, clips.Length);
            neutralName = library.idles[0].name;
            playbackSpeed = Mathf.Clamp(library.portraitPlaybackSpeed, .25f, 1.5f);
            transitionSeconds = Mathf.Max(.2f, library.portraitTransitionSeconds);
            contactReleaseSeconds = Mathf.Max(.2f, library.portraitContactReleaseSeconds);
            for (int i=0;i<clips.Length;i++) {
                AnimationClip clip = i == 0 ? library.idles[0]
                    : i < PhoneSlot ? library.Find(EmotionSnapshot.Keys[i])?.clip
                    : i == PhoneSlot ? library.Find("researching_state")?.clip
                    : i == SleepSlot ? (library.sleeping != null ? library.sleeping : library.idles[0])
                    : library.idles[i-FirstIdleSlot+1];
                if (clip == null) throw new InvalidOperationException("Standing portrait clip missing at "+i);
                sources[i] = clip; lengths[i] = Mathf.Max(.01f,clip.length);
                clips[i] = AnimationClipPlayable.Create(graph,clip); clips[i].SetApplyFootIK(false);
                graph.Connect(clips[i],0,mixer,i);
            }
            weights[0] = 1; mixer.SetInputWeight(0,1);
            var output = AnimationPlayableOutput.Create(graph,"Main portrait body",animator);
            if (library.breathing != null && library.breathing.length > 0) {
                breathing = AnimationClipPlayable.Create(graph, library.breathing);
                breathing.SetApplyFootIK(false);
                breathingLength = library.breathing.length;
                var layers = AnimationLayerMixerPlayable.Create(graph, 2);
                graph.Connect(mixer, 0, layers, 0); layers.SetInputWeight(0, 1);
                graph.Connect(breathing, 0, layers, 1); layers.SetInputWeight(1, 1);
                layers.SetLayerAdditive(1, true);
                output.SetSourcePlayable(layers);
            } else output.SetSourcePlayable(mixer);
            animator.runtimeAnimatorController = null; graph.Play();
        }

        float NextIdleDelay() => 24f + (float)idleRandom.NextDouble()*16f;
        public void NotifyActivity() { idleElapsed = 0; idleSlot = -1; }
        public static int Dominant(float[] emotions)
        {
            int selected=0; float maximum=0;
            foreach(int i in MainPriority) if(emotions[i]>maximum){maximum=emotions[i];selected=i;}
            return selected;
        }
        public Vector2 Apply(float[] emotions,bool researching,float dt,string previewKey,float previewTime,bool sleeping=false,bool idleState=true)
        {
            dt = Mathf.Max(0,dt); clock += dt*playbackSpeed;
            target = sleeping ? SleepSlot : researching ? PhoneSlot : Dominant(emotions);
            int previewSlot = -1;
            if (!string.IsNullOrEmpty(previewKey)) {
                if (previewKey == "sleeping") target=SleepSlot;
                else if (previewKey=="researching_state" || previewKey=="investigate") target=PhoneSlot;
                else if (previewKey=="thinking_state") target=10;
                else if (previewKey==neutralName || previewKey=="listening_state") target=0;
                else {
                    int i=Array.IndexOf(EmotionSnapshot.Keys,previewKey);
                    if(i>=0) target=i;
                    else for(int j=FirstIdleSlot;j<sources.Length;j++)
                        if(sources[j].name==previewKey){target=0;previewSlot=j;break;}
                }
            }

            bool canIdle = target==0 && idleState && !sleeping && !researching && string.IsNullOrEmpty(previewKey);
            if (!canIdle) { idleElapsed=0; idleSlot=-1; }
            else if (idleSlot>=FirstIdleSlot) {
                int n=idleSlot-FirstIdleSlot; idleTimes[n]+=dt*playbackSpeed;
                if(idleTimes[n]>=lengths[idleSlot]) { idleTimes[n]=lengths[idleSlot]; idleSlot=-1; idleElapsed=0; nextIdleAfter=NextIdleDelay(); }
            } else if (idleTimes.Length>0) {
                idleElapsed += dt;
                if(idleElapsed>=nextIdleAfter) {
                    int choice=idleRandom.Next(idleTimes.Length);
                    if(idleTimes.Length>1 && FirstIdleSlot+choice==lastIdleSlot) choice=(choice+1+idleRandom.Next(idleTimes.Length-1))%idleTimes.Length;
                    idleSlot=FirstIdleSlot+choice; lastIdleSlot=idleSlot; idleTimes[choice]=0; idleElapsed=0;
                }
            }
            if (target!=previousTarget) {
                if((Contact(previousTarget)||Contact(target)) && weights[0]<.8f) releaseTime=contactReleaseSeconds;
                previousTarget=target;
            }
            releaseTime=Mathf.Max(0,releaseTime-dt);
            int blendTarget=releaseTime>0 ? 0 : previewSlot>=0 ? previewSlot : idleSlot>=0 ? idleSlot : target;
            float rate=releaseTime>0 ? 4/contactReleaseSeconds : 3/transitionSeconds;
            float alpha=1-Mathf.Exp(-dt*rate);
            for(int i=0;i<clips.Length;i++) {
                weights[i]=previewTime>=0 ? (i==blendTarget?1:0) : Mathf.Lerp(weights[i],i==blendTarget?1:0,alpha);
                mixer.SetInputWeight(i,weights[i]);
                float t=previewTime>=0 ? Mathf.Clamp(previewTime,0,lengths[i])
                    : i>=FirstIdleSlot && previewSlot!=i ? idleTimes[i-FirstIdleSlot] : clock%lengths[i];
                clips[i].SetTime(t);
            }
            if (breathing.IsValid()) {
                breathingClock += dt;
                breathing.SetTime(breathingClock % breathingLength);
            }
            graph.Evaluate(0);
            // The phone is on the character's right. The authored eye shapes
            // use positive X toward it and negative Y for a downward gaze.
            return new Vector2(22,-18)*weights[PhoneSlot];
        }
        static bool Contact(int i)=>i==2||i==3||i==10||i==PhoneSlot;
        public void Dispose(){if(graph.IsValid())graph.Destroy();}
    }
}

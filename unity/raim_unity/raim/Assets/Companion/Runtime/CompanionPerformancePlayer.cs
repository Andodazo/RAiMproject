using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

namespace RAiM.Companion
{
    // Owns body playback. A phrase preserves one readable physical intention while
    // continuous emotion mixing remains in the actor's face and subtle posture.
    public sealed class CompanionPerformancePlayer : IDisposable
    {
        readonly PlayableGraph graph;
        readonly AnimationMixerPlayable mixer;
        readonly AnimationClipPlayable[] slots;
        readonly PerformanceLibrary library;
        readonly StandingPortraitPlayer standing;
        readonly float[] idleWeights;
        readonly int idleCount,phraseSlot;
        AnimationClipPlayable phrasePlayable;
        PerformancePhrase active;
        readonly float[] nextAllowed=new float[12];
        float clock, phraseClock, phraseWeight, talkWeight;
        int lastEmotion=-1, variant;
        BehaviorState previous=(BehaviorState)(-1);
        string previousReaction="";
        string pending="";
        readonly Dictionary<string, int> variants = new Dictionary<string, int>();
        float exitClock=-1;
        public string Active=>standing?.Active??active?.key??"idle";
        public float Phase=>standing?.Phase??(active==null?0:phraseClock/active.clip.length);
        public float PhoneWeight=>standing?.PhoneWeight??0;
        public string ActiveMotion=>standing?.ActiveMotion??active?.key??"idle";
        public bool Frozen;
        public float PreviewTime=-1;
        public string PreviewKey="";
        public CompanionPerformancePlayer(Animator animator,PerformanceLibrary library)
        {
            this.library=library;
            if(library.standingPortraitMode){standing=new StandingPortraitPlayer(animator,library);return;}
            idleCount=library.idles.Length;phraseSlot=idleCount+1;idleWeights=new float[idleCount];idleWeights[0]=1;
            graph=PlayableGraph.Create("RAiM authored performance");graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            mixer=AnimationMixerPlayable.Create(graph,idleCount+2);slots=new AnimationClipPlayable[idleCount+1];
            for(int i=0;i<slots.Length;i++) {
                slots[i]=AnimationClipPlayable.Create(graph,i==idleCount?library.talk:library.idles[i]);
                slots[i].SetApplyFootIK(false);graph.Connect(slots[i],0,mixer,i);
            }
            var output=AnimationPlayableOutput.Create(graph,"Authored body",animator);output.SetSourcePlayable(mixer);
            animator.runtimeAnimatorController=null;graph.Play();
        }
        void StartPhrase(string key)
        {
            variants.TryGetValue(key, out int nextVariant);
            var phrase=library.Find(key, nextVariant);
            if (phrase != null) variants[key] = (nextVariant + 1) % Array.FindAll(library.phrases, p => p != null && p.key == key && p.clip != null).Length;
            if(phrase==null&&PreviewKey==key) {
                AnimationClip clip=library.talk.name==key?library.talk:null;
                foreach(var idle in library.idles)if(idle.name==key)clip=idle;
                if(clip!=null)phrase=new PerformancePhrase{key=key,clip=clip,readableTime=clip.length*.5f};
            }
            if(phrase?.clip==null)return;
            // Transitions enter from each authored neutral preparation, never a T-pose.
            if(phrasePlayable.IsValid()){mixer.DisconnectInput(phraseSlot);graph.DestroyPlayable(phrasePlayable);}
            active=phrase;phraseClock=0;phraseWeight=0;
            exitClock=-1;
            phrasePlayable=AnimationClipPlayable.Create(graph,phrase.clip);phrasePlayable.SetApplyFootIK(false);
            graph.Connect(phrasePlayable,0,mixer,phraseSlot);
        }
        public void NotifyActivity(){standing?.NotifyActivity();}
        public Vector2 Apply(float[] emotions,BehaviorState state,EmotionProfile profile,float dt,string reaction,float[] selection=null,bool externalWork=false,bool sleeping=false)
        {
            if(Frozen)dt=0;
            if(standing!=null)return standing.Apply(selection??emotions,externalWork||state==BehaviorState.Researching,dt,PreviewKey,PreviewTime,sleeping,state==BehaviorState.Idle);
            clock+=dt;
            int strongest=1;for(int i=2;i<12;i++)if(emotions[i]>emotions[strongest])strongest=i;
            if(emotions[strongest]<.18f)strongest=0;
            bool stateChanged=state!=previous;
            string stateKey=state==BehaviorState.Thinking?"thinking_state":state==BehaviorState.Researching?"researching_state":state==BehaviorState.Listening?"listening_state":"";
            if(!string.IsNullOrEmpty(PreviewKey)&&active?.key!=PreviewKey)StartPhrase(PreviewKey);
            else if(string.IsNullOrEmpty(PreviewKey)) {
                if(stateChanged&&active!=null&&active.key!=stateKey&&(active.key.EndsWith("_state")||stateKey!="")){pending=stateKey;exitClock=0;}
                if(reaction!=""&&reaction!=previousReaction&&active!=null){pending=reaction=="surprise"?"surprised":reaction;exitClock=0;}
                if(active==null&&pending!=""){StartPhrase(pending);pending="";}
                if(active==null && (stateChanged||state==BehaviorState.Thinking||state==BehaviorState.Researching)) {
                    string key=state==BehaviorState.Thinking?"thinking_state":state==BehaviorState.Researching?"researching_state":state==BehaviorState.Listening?"listening_state":"";
                    if(key!="")StartPhrase(key);
                }
                if(reaction!=""&&reaction!=previousReaction&&active==null)StartPhrase(reaction=="surprise"?"surprised":reaction);
                if(active==null&&strongest>0&&clock>=nextAllowed[strongest]&&(strongest!=lastEmotion||clock>=nextAllowed[strongest]+8)) {
                    StartPhrase(EmotionSnapshot.Keys[strongest]);
                    nextAllowed[strongest]=clock+Mathf.Max(profile.gestureInterval*2.5f,active?.minimumInterval??12);
                    lastEmotion=strongest;
                }
            }
            previous=state;previousReaction=reaction;
            float idleCycle=clock%52;
            variant=idleCount>=3?(idleCycle<30?0:idleCycle<42?1:idleCycle<46?2:0):(int)(clock/17)%idleCount;
            for(int i=0;i<idleCount;i++)idleWeights[i]=Mathf.Lerp(idleWeights[i],i==variant?1:0,1-Mathf.Exp(-dt*.65f));
            float talkCycle=clock%(library.talk.length/.86f+3.2f);
            bool talkBeat=talkCycle<library.talk.length/.86f;
            talkWeight=Mathf.MoveTowards(talkWeight,state==BehaviorState.Speaking&&talkBeat?.65f:0,dt*1.6f);
            for(int i=0;i<slots.Length;i++)slots[i].SetTime(clock*(i==idleCount?.86f:1)%(i==idleCount?library.talk.length:library.idles[i].length));
            slots[idleCount].SetTime(Mathf.Min(talkCycle*.86f,library.talk.length));
            if(active!=null) {
                phraseClock=PreviewTime>=0?Mathf.Clamp(PreviewTime,0,active.clip.length):phraseClock+dt;
                bool statePhrase=active.key.EndsWith("_state");
                float strength=statePhrase?1:active.key=="nod"||active.key=="discovery"?profile.gestureStrength:Mathf.Clamp01((1-emotions[0])*profile.bodyGain);
                if(PreviewKey!="")strength=1;
                float enter=Smooth(phraseClock/.32f),exit=Smooth((active.clip.length-phraseClock)/.7f);
                phraseWeight=strength*enter*exit;
                if(exitClock>=0){exitClock+=dt;phraseWeight*=1-Smooth(exitClock/.45f);}
                phrasePlayable.SetTime(Mathf.Min(phraseClock,active.clip.length));
                if((phraseClock>=active.clip.length||exitClock>=.45f)&&PreviewTime<0){active=null;phraseWeight=0;exitClock=-1;}
            }
            for(int i=0;i<idleCount;i++)mixer.SetInputWeight(i,(1-phraseWeight)*(1-talkWeight)*idleWeights[i]);
            mixer.SetInputWeight(idleCount,(1-phraseWeight)*talkWeight);
            mixer.SetInputWeight(phraseSlot,phraseWeight);
            graph.Evaluate(0);
            Vector2 gaze=Vector2.zero;
            for(int i=1;i<12;i++)gaze+=profile.emotions[i].gaze*emotions[i]*.45f;
            if(state==BehaviorState.Researching)gaze+=new Vector2(Mathf.Lerp(-12,14,Smooth((clock%6)/3)), -5);
            if(state==BehaviorState.Thinking)gaze+=new Vector2(9,5);
            return gaze;
        }
        static float Smooth(float t){t=Mathf.Clamp01(t);return t*t*(3-2*t);}
        public void Dispose(){standing?.Dispose();if(graph.IsValid())graph.Destroy();}
    }
}

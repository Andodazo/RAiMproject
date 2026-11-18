using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

namespace RAiM.Companion
{
    public sealed class StandingPortraitPlayer : IDisposable
    {
        static readonly string[] Accents = { "idle_look", "idle_weight", "idle_far", "idle_arms" };
        readonly Dictionary<string, int> slots = new Dictionary<string, int>();
        readonly List<string> keys = new List<string>();
        readonly List<AnimationClip> clips = new List<AnimationClip>();
        readonly PlayableGraph graph;
        readonly AnimationMixerPlayable mixer;
        readonly AnimationClipPlayable[] players;
        readonly float[] weights, starts, times;
        readonly List<int> remainingAccents = new List<int>(4);
        readonly System.Random random;
        int current, neutral, chosenEmotion, candidate, lastAccent = -1;
        float blendAge, blendDuration, inactive, nextDraw, candidateAge, behaviorAge;
        float speechGap, thoughtGap;
        string spokenPose;
        long replyId, replyGeneration;
        string replyPose;
        bool replyFinished;
        float speechAge;
        float reportRemaining, reactionRemaining;
        string accent, activeReaction, lastReaction;
        BehaviorState previousState;
        bool wasResearching, nodded, idleBlocked;
        public string Active => keys[current];
        public string ActiveMotion => clips[current].name;
        public float Phase => SampleTime(current) / clips[current].length;
        public float PhoneWeight => Weight("researching_state") + Weight("phone_report");
        float Weight(string key) => slots.TryGetValue(key, out int i) ? weights[i] : 0;

        public StandingPortraitPlayer(Animator animator, PerformanceLibrary library, int? seed = null)
        {
            random = new System.Random(seed ?? Guid.NewGuid().GetHashCode());
            NotifyActivity();
            Add("neutral",library.idles[0]);
            foreach (var phrase in library.phrases) Add(phrase.key, phrase.clip);
            Add("sleeping",library.sleeping);
            Add("speaking_state",library.talk);
            graph = PlayableGraph.Create("RAiM portrait performances");
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            mixer = AnimationMixerPlayable.Create(graph, clips.Count);
            players = new AnimationClipPlayable[clips.Count];
            weights = new float[clips.Count]; starts = new float[clips.Count]; times = new float[clips.Count];
            for (int i = 0; i < clips.Count; i++) {
                players[i] = AnimationClipPlayable.Create(graph,clips[i]);
                players[i].SetApplyFootIK(false);
                graph.Connect(players[i],0,mixer,i);
            }
            weights[0] = starts[0] = 1; mixer.SetInputWeight(0,1);
            var output = AnimationPlayableOutput.Create(graph,"Standing character",animator);
            animator.runtimeAnimatorController = null; output.SetSourcePlayable(mixer); graph.Play();
        }
        void Add(string key, AnimationClip clip)
        {
            if (!clip || slots.ContainsKey(key)) return;
            slots.Add(key,clips.Count); keys.Add(key); clips.Add(clip);
        }
        float Delay(float minimum,float maximum) => minimum+(maximum-minimum)*(float)random.NextDouble();
        public void NotifyActivity() { inactive = 0; nextDraw = Delay(8,13); accent = null; }
        public static int Dominant(float[] emotions)
        {
            int best = 0;
            for (int i=1;i<12;i++) if (emotions[i]>emotions[best]) best=i;
            return best;
        }
        int SelectEmotion(float[] e, float dt)
        {
            int best = 1;
            for(int i=2;i<12;i++) if(e[i]>e[best]) best=i;
            if (1-e[0]<.24f || e[best]<.16f) best=0;
            if (chosenEmotion!=0 && best!=0 && e[best]<e[chosenEmotion]+.12f) best=chosenEmotion;
            if (candidate!=best) { candidate=best; candidateAge=0; }
            candidateAge+=dt;
            if (candidateAge >= (best==4 ? .12f : chosenEmotion==0 ? .22f : .6f)) chosenEmotion=best;
            return chosenEmotion;
        }
        string NextAccent()
        {
            if(remainingAccents.Count==0) for(int i=0;i<Accents.Length;i++) remainingAccents.Add(i);
            int pick=random.Next(remainingAccents.Count);
            if(remainingAccents.Count>1 && remainingAccents[pick]==lastAccent)
                pick=(pick+1+random.Next(remainingAccents.Count-1))%remainingAccents.Count;
            lastAccent=remainingAccents[pick];
            remainingAccents.RemoveAt(pick);
            return Accents[lastAccent];
        }
        string Idle()
        {
            if(accent!=null && Active==accent && times[current]>=clips[current].length) {
                accent=null;
                neutral=neutral==0 ? slots["neutral_alt"] : 0;
                nextDraw=inactive+Delay(10,18);
            }
            if(accent==null && inactive>=nextDraw) accent=NextAccent();
            if(accent!=null) return accent;
            if(current==neutral && times[current]>=clips[current].length)
                neutral=neutral==0 ? slots["neutral_alt"] : 0;
            return keys[neutral];
        }
        static bool Contact(string key) => key=="angry" || key=="sad" || key=="thoughtful" || key=="thinking_state" || key=="researching_state";
        // Audio is streamed in chunks. A short silence within one reply must not restart its body clip.
        BehaviorState ConversationState(BehaviorState input,float dt,bool urgent)
        {
            if(input==BehaviorState.Speaking && !urgent) speechGap=.65f;
            else if(urgent || input==BehaviorState.Listening || input==BehaviorState.Thinking) speechGap=0;
            else speechGap=Mathf.Max(0,speechGap-dt);
            if(input==BehaviorState.Thinking && !urgent) thoughtGap=.35f;
            else if(input!=BehaviorState.Idle || urgent) thoughtGap=0;
            else thoughtGap=Mathf.Max(0,thoughtGap-dt);
            if(input==BehaviorState.Idle && thoughtGap>0) return BehaviorState.Thinking;
            return input==BehaviorState.Idle && speechGap>0 ? BehaviorState.Speaking : input;
        }

        string ConversationPose(BehaviorState state,string emotion,float strength)
        {
            string carry=Active=="sleeping" || Active=="researching_state" || Active=="phone_report" ? "neutral" : Active;
            if(state==BehaviorState.Thinking)
                return behaviorAge<.85f ? carry : "thinking_state";
            if(state==BehaviorState.Listening)
                return emotion!="neutral" && strength>=.55f ? emotion : "listening_state";
            if(state!=BehaviorState.Speaking) return emotion;

            // Let metadata and the first audio chunk meet before committing the hands.
            // The expression compositor and mouth are already responding independently.
            bool expressive=emotion!="neutral" && strength>=.55f;
            if(spokenPose==null) {
                if(expressive) spokenPose=emotion;
                else if(behaviorAge>=.85f) spokenPose="speaking_state";
                else return carry;
            }
            // A late cue can follow the completed speaking gesture, without cutting it in half.
            bool canReceiveCue=spokenPose=="speaking_state"
                ? times[current]<2.1f || times[current]>=6.4f : times[current]>=2.8f;
            if(expressive && Active==spokenPose && canReceiveCue)
                spokenPose=emotion;
            return spokenPose;
        }

        // A reply survives text, metadata and individual audio chunks changing independently.
        string ReplyPose(BehaviorState state, bool open, int cue, float dt)
        {
            if (replyFinished) return state == BehaviorState.Listening ? "listening_state" : "neutral";
            if (replyPose == null) {
                if (state == BehaviorState.Speaking) speechAge += dt;
                if (cue > 0) replyPose = EmotionSnapshot.Keys[cue];
                else if (speechAge >= .85f) replyPose = "speaking_state";
                else if (state == BehaviorState.Thinking && behaviorAge >= .85f) return "thinking_state";
                else if (state == BehaviorState.Listening) return "listening_state";
                else return Active == "thinking_state" && open ? Active : "neutral";
            }
            if (!open && state != BehaviorState.Speaking && Active == replyPose && times[current] >= 3f) {
                replyFinished = true;
                return "neutral";
            }
            return replyPose;
        }

        void Switch(int next,float duration)
        {
            if(current==next) return;
            Array.Copy(weights,starts,weights.Length);
            if(weights[next]<.015f) times[next]=keys[next]=="thinking_state" ? Mathf.Min(.85f,behaviorAge) : 0;
            current=next;
            blendAge=0; blendDuration=duration;
        }
        float SampleTime(int i)
        {
            float t=times[i], end=clips[i].length;
            if(t<end) return t;
            string key=keys[i];
            if(key.StartsWith("idle_",StringComparison.Ordinal) || key=="nod" || key=="discovery" || key=="phone_report") return end;
            if(key=="neutral" || key=="neutral_alt") return t%end;
            // The last four seconds are authored as a seamless breathing hold.
            return end-4+(t-end)%4;
        }
        public Vector2 Apply(float[] emotions,bool researching,float dt,string previewKey,float previewTime,bool sleeping=false,bool idleState=true,
            BehaviorState state=BehaviorState.Idle,string reaction="",CompanionState transport=null,int replyEmotion=-1)
        {
            dt=Mathf.Max(0,dt);
            bool tracked = transport != null && transport.ReplyId > 0;
            if (!tracked || replyId != transport.ReplyId || replyGeneration != transport.Generation) {
                replyId = tracked ? transport.ReplyId : 0;
                replyGeneration = tracked ? transport.Generation : -1;
                replyPose = null; replyFinished = false; speechAge = 0;
            }
            state=ConversationState(state,dt,sleeping || researching);
            if(state!=previousState || sleeping || researching) {
                behaviorAge=0; nodded=false; spokenPose=null; previousState=state;
            }
            behaviorAge+=dt;
            if(wasResearching && !researching && !sleeping && (state==BehaviorState.Speaking || reaction=="discovery")) reportRemaining=1.8f;
            wasResearching=researching;
            if(researching || sleeping) reportRemaining=0;
            bool surpriseCue = reaction == "surprise" && (!tracked || !replyFinished && replyPose == null);
            if(reaction!=lastReaction && (reaction=="nod" || reaction=="discovery" || surpriseCue)) {
                activeReaction=reaction=="surprise" ? "surprised" : reaction;
                reactionRemaining=activeReaction=="nod"?1.7f:2;
            }
            lastReaction=reaction;
            if(state==BehaviorState.Listening && behaviorAge>14 && !nodded && !sleeping && !researching) {
                activeReaction="nod"; reactionRemaining=1.7f; nodded=true;
            }
            // The confirmed result may arrive one update before the tool-state reset.
            if(reportRemaining>0 && activeReaction=="discovery" && reactionRemaining>0)
                reactionRemaining=Mathf.Max(reactionRemaining,reportRemaining+1.55f);
            string requested=EmotionSnapshot.Keys[SelectEmotion(emotions,dt)];
            if (tracked) {
                if (sleeping || researching && replyPose != null || reportRemaining > 0 || reactionRemaining > 0 && activeReaction == "discovery")
                    replyFinished = true;
                else if (reactionRemaining > 0 && activeReaction == "surprised" && !replyFinished)
                    replyPose = "surprised";
            }
            if(sleeping) requested="sleeping";
            else if(researching) requested="researching_state";
            else if(reportRemaining>0) requested="phone_report";
            else if(reactionRemaining>0) requested=activeReaction;
            else if(tracked) requested=ReplyPose(state,transport.ReplyOpen,replyEmotion,dt);
            else requested=ConversationPose(state,requested,emotions[chosenEmotion]);
            bool canRest=(!tracked || !transport.ReplyOpen) && idleState && state==BehaviorState.Idle && !sleeping && !researching &&
                reportRemaining<=0 && reactionRemaining<=0 && string.IsNullOrEmpty(previewKey);
            if(canRest) {
                if(idleBlocked) NotifyActivity();
                inactive+=dt;
                // After the reaction has read, release the body even if the server retains the last emotion.
                // The face keeps its independently composed expression.
                if(requested=="neutral" || inactive>=4.5f) requested=Idle();
            } else if(!idleBlocked) {
                NotifyActivity();
            }
            idleBlocked=!canRest;
            reportRemaining-=dt; reactionRemaining-=dt;
            if(!string.IsNullOrEmpty(previewKey)) {
                if(previewKey=="investigate") previewKey="researching_state";
                if(!slots.ContainsKey(previewKey)) {
                    int index=clips.FindIndex(c=>c.name==previewKey);
                    if(index>=0) previewKey=keys[index];
                }
                if(slots.ContainsKey(previewKey)) requested=previewKey;
            }
            int next=slots[requested];
            // Incoming contact clips already contain the reach from rest. Crossfade out
            // of the old grip directly, so the player never inserts a separate idle clip.
            float duration=requested=="surprised" ? .68f : requested=="phone_report" ? .65f :
                Contact(Active) && Contact(requested) ? 1.12f : .94f;
            Switch(next,duration);
            blendAge+=dt;
            float blend=previewTime>=0 || blendDuration<=0 ? 1 : Mathf.SmoothStep(0,1,blendAge/blendDuration);
            for(int i=0;i<clips.Count;i++) {
                weights[i]=Mathf.Lerp(starts[i],i==current?1:0,blend);
                mixer.SetInputWeight(i,weights[i]);
                if(weights[i]<=0) continue;
                if(previewTime>=0 && i==current) times[i]=Mathf.Clamp(previewTime,0,clips[i].length);
                else times[i]+=dt;
                players[i].SetTime(previewTime>=0 && i==current ? times[i] : SampleTime(i));
            }
            graph.Evaluate(0);
            float gazeTurn=Weight("idle_look")*Pulse("idle_look",.1f,1.1f,2.4f,3.8f)
                +Weight("idle_far")*Pulse("idle_far",.2f,1.5f,3.4f,4.7f);
            return new Vector2(22,-18)*Weight("researching_state") + new Vector2(9,4)*gazeTurn
                +new Vector2(-8,5)*(Weight("thinking_state")+Weight("thoughtful"))
                +new Vector2(-7,-4)*Weight("embarrassed")*Pulse("embarrassed",0,.55f,1.4f,2.8f)
                +new Vector2(0,-4)*Weight("sad");
        }
        float Pulse(string key,float start,float peak,float hold,float end)
        {
            float t=times[slots[key]];
            return Mathf.SmoothStep(0,1,Mathf.InverseLerp(start,peak,t))*(1-Mathf.SmoothStep(0,1,Mathf.InverseLerp(hold,end,t)));
        }
        public void Dispose(){if(graph.IsValid())graph.Destroy();}
    }
}
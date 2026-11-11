using UnityEngine;

namespace RAiM.Companion
{
    // Model-sized choreography. The network still supplies the same twelve weights.
    // All hand targets are in the character root's local space, in metres.
    public sealed class CompanionGestureDirector
    {
        public struct Gesture
        {
            public Vector3 left, right, leftForward, rightForward, leftPalm, rightPalm;
            public Vector4 leftGrip, rightGrip;
            public float leftThumb, rightThumb;
            public Vector3 hips, hipsAngles, head, chest, leftFoot, rightFoot, leftFootAngles, rightFootAngles;
        }
        readonly CompanionPoseRig rig;
        float thinking, entryTime;
        int priorDominant;
        public float ThinkingWeight => thinking;
        public Vector4 LeftGrip { get; private set; }
        public Vector4 RightGrip { get; private set; }
        public CompanionGestureDirector(CompanionPoseRig rig) { this.rig=rig; }
        static Vector4 Grip(float value) => Vector4.one * value;
        public static Gesture Emotion(int key, float time)
        {
            float beat=.5f-.5f*Mathf.Cos(time*Mathf.PI*2/4.2f);
            float wave=Mathf.Sin(time*5), laugh=Mathf.Sin(time*9);
            float leftBounce=Mathf.Pow(Mathf.Max(0,Mathf.Sin(time*4)),2);
            float rightBounce=Mathf.Pow(Mathf.Max(0,-Mathf.Sin(time*4)),2);
            var p=new Gesture { left=new Vector3(-.22f,.83f,.16f),right=new Vector3(.22f,.86f,.16f),
                leftForward=Vector3.down,rightForward=Vector3.down,leftPalm=Vector3.forward,rightPalm=Vector3.forward,
                leftGrip=Grip(.16f),rightGrip=Grip(.16f),leftThumb=.15f,rightThumb=.15f };
            switch(key)
            {
                case 1: // happy: a recognisable open-hand wave and a light heel bounce
                    p.right=new Vector3(.31f+wave*.035f,1.32f,.22f);p.rightForward=new Vector3(wave*.45f,1,0);
                    p.rightGrip=new Vector4(.08f,.12f,.16f,.2f)+Grip((wave*.5f+.5f)*.12f);
                    p.left=new Vector3(-.18f,.94f,.22f);p.leftFootAngles.x=beat*13;p.hips.y=beat*.014f;
                    break;
                case 2: // sad: close the silhouette, sag, and quietly clasp hands
                    p.left=new Vector3(-.06f,.84f,.27f);p.right=new Vector3(.045f,.88f,.29f);
                    p.leftForward=new Vector3(1,-.35f,0);p.rightForward=new Vector3(-1,-.35f,0);
                    p.leftGrip=Grip(.38f+beat*.12f);p.rightGrip=Grip(.5f);p.leftThumb=p.rightThumb=.6f;
                    p.hips=new Vector3(-.025f,-.047f,.018f);p.chest.x=8;p.head.x=4;
                    p.leftFootAngles.y=9;p.rightFootAngles.y=-9;
                    break;
                case 3: // angry: fists close beside the ribs; a small emphatic foot tap
                    p.left=new Vector3(-.25f,1.05f+wave*.012f,.2f);p.right=new Vector3(.25f,1.1f-wave*.012f,.2f);
                    p.leftForward=p.rightForward=Vector3.up;p.leftPalm=p.rightPalm=Vector3.back;
                    p.leftGrip=p.rightGrip=Grip(.9f+beat*.08f);p.leftThumb=p.rightThumb=1;
                    p.hips=new Vector3(0,-.025f,.04f);p.leftFoot.x=-.05f;p.rightFoot.x=.05f;p.rightFoot.y=rightBounce*.028f;
                    p.chest.x=6;
                    break;
                case 4: // surprised: open fingers near the cheeks, recoiling onto one foot
                    p.left=new Vector3(-.24f,1.34f,.2f);p.right=new Vector3(.24f,1.34f,.2f);
                    p.leftForward=new Vector3(-.3f,1,0);p.rightForward=new Vector3(.3f,1,0);
                    p.leftGrip=p.rightGrip=Grip(.02f+beat*.05f);p.hips=new Vector3(0,-.03f,-.065f);p.chest.x=-7;
                    p.rightFoot=new Vector3(.045f,0,-.13f);p.rightFootAngles.y=16;
                    break;
                case 5: // caring: one hand at the chest, one offered palm
                    p.left=new Vector3(-.1f,1.16f,.19f);p.right=new Vector3(.27f,1.00f+beat*.04f,.39f);
                    p.leftForward=new Vector3(.7f,.5f,0);p.rightForward=new Vector3(.4f,.15f,1);
                    p.leftPalm=Vector3.back;p.rightPalm=Vector3.up;p.leftGrip=Grip(.3f);p.rightGrip=Grip(.13f+beat*.12f);
                    p.hips.z=.035f;p.chest.x=6;p.rightFoot.z=.07f;
                    break;
                case 6: // embarrassed: hand near mouth, fingers fidgeting, turned-in stance
                    p.left=new Vector3(-.09f,1.31f,.22f);p.right=new Vector3(.14f,1.03f,.27f);
                    p.leftForward=new Vector3(.35f,1,0);p.rightForward=new Vector3(-.3f,.8f,.1f);
                    p.leftPalm=Vector3.back;p.rightPalm=Vector3.back;
                    p.leftGrip=new Vector4(.15f,.3f,.4f,.5f)+Grip((wave*.5f+.5f)*.17f);
                    p.rightGrip=new Vector4(.35f,.55f,.55f,.45f)+Grip((Mathf.Sin(time*5+1)*.5f+.5f)*.18f);
                    p.leftThumb=.35f;p.rightThumb=.65f;p.hips=new Vector3(-.04f,-.025f,0);
                    p.rightFoot=new Vector3(-.025f,0,.035f);p.leftFootAngles.y=10;p.rightFootAngles.y=-14;
                    break;
                case 7: // excited: alternating fist pumps, knees and feet joining the beat
                    p.left=new Vector3(-.25f,1.08f+leftBounce*.31f,.24f);p.right=new Vector3(.25f,1.08f+rightBounce*.31f,.24f);
                    p.leftForward=p.rightForward=Vector3.up;p.leftPalm=p.rightPalm=Vector3.back;
                    p.leftGrip=Grip(.7f+leftBounce*.28f);p.rightGrip=Grip(.7f+rightBounce*.28f);p.leftThumb=p.rightThumb=1;
                    p.hips=new Vector3((rightBounce-leftBounce)*.035f,-.025f+(leftBounce+rightBounce)*.035f,0);
                    p.leftFoot=new Vector3(-leftBounce*.045f,leftBounce*.07f,leftBounce*.04f);
                    p.rightFoot=new Vector3(rightBounce*.045f,rightBounce*.07f,rightBounce*.04f);
                    p.leftFootAngles.x=rightBounce*14;p.rightFootAngles.x=leftBounce*14;
                    break;
                case 8: // curious: index finger up, a lean and a tentative step
                    p.right=new Vector3(.18f,1.28f+beat*.025f,.27f);p.left=new Vector3(-.19f,.96f,.2f);
                    p.rightForward=new Vector3(.1f,1,.25f);p.rightPalm=Vector3.left;
                    p.rightGrip=new Vector4(.03f,.92f,.96f,.96f);p.rightThumb=.8f;p.leftGrip=Grip(.45f);
                    p.hips=new Vector3(.025f,-.025f,.045f);p.rightFoot.z=.10f;p.rightFootAngles.y=-6;
                    break;
                case 9: // amused: cover a smile, hold stomach, laugh through the chest
                    p.right=new Vector3(.06f,1.31f,.22f);p.left=new Vector3(-.08f,.97f,.25f);
                    p.rightForward=new Vector3(-.2f,1,0);p.rightPalm=Vector3.back;p.leftForward=Vector3.right;
                    p.rightGrip=Grip(.45f+(laugh*.5f+.5f)*.18f);p.leftGrip=Grip(.3f);p.rightThumb=.65f;
                    p.chest.x=4+Mathf.Abs(laugh)*4;p.hips.y=-.02f+Mathf.Abs(laugh)*.009f;p.rightFootAngles.x=beat*15;
                    break;
                case 10: // thoughtful: contact is solved after head movement
                    p.right=new Vector3(.04f,1.27f,.16f);p.left=new Vector3(-.06f,1.05f,.25f);
                    p.rightForward=Vector3.up;p.rightPalm=Vector3.back;p.leftForward=Vector3.right;p.leftPalm=Vector3.up;
                    p.rightGrip=Grip(.94f);p.leftGrip=Grip(.3f);p.rightThumb=1;p.leftThumb=.3f;
                    p.hips.x=-.045f;p.rightFoot.z=.09f;p.rightFootAngles.y=8;
                    break;
                case 11: // playful: a V sign, a loose wave and a side step
                    p.right=new Vector3(.18f,1.37f,.19f);p.left=new Vector3(-.32f+wave*.025f,1.15f,.24f);
                    p.rightForward=new Vector3(.2f,1,0);p.leftForward=new Vector3(-.4f+wave*.3f,1,0);
                    p.rightGrip=new Vector4(.03f,.04f,.95f,.97f);p.rightThumb=.95f;
                    p.leftGrip=new Vector4(.1f,.15f,.25f,.35f)+Grip((wave*.5f+.5f)*.15f);
                    p.hips=new Vector3(-beat*.045f,-.022f,0);p.leftFoot=new Vector3(-beat*.13f,Mathf.Sin(beat*Mathf.PI)*.065f,.02f*beat);
                    p.leftFootAngles.y=-beat*16;p.rightFootAngles.x=beat*12;
                    break;
            }
            return p;
        }
        public Vector2 Apply(EmotionProfile profile,float[] weights,BehaviorState state,float time,float dt,string reaction,float reactionPhase)
        {
            int dominant=0;for(int i=1;i<12;i++)if(weights[i]>weights[dominant])dominant=i;
            if(dominant!=priorDominant){priorDominant=dominant;entryTime=time;}
            float age=time-entryTime;
            float gain=Mathf.Max(0,profile.bodyGain),total=0;for(int i=1;i<12;i++)total+=weights[i]*gain;
            if(total>1){gain/=total;total=1;}
            Vector3 l=Vector3.zero,r=Vector3.zero,lf=Vector3.zero,rf=Vector3.zero,lp=Vector3.zero,rp=Vector3.zero;
            Vector3 hips=Vector3.zero,ha=Vector3.zero,head=Vector3.zero,chest=Vector3.zero,leftFoot=Vector3.zero,rightFoot=Vector3.zero,la=Vector3.zero,ra=Vector3.zero;
            Vector4 lg=Vector4.zero,rg=Vector4.zero;float lt=0,rt=0;Vector2 gaze=Vector2.zero;
            for(int i=1;i<12;i++)
            {
                float w=weights[i]*gain;if(w<=.0001f)continue;var p=Emotion(i,age);
                l+=p.left*w;r+=p.right*w;lf+=p.leftForward*w;rf+=p.rightForward*w;lp+=p.leftPalm*w;rp+=p.rightPalm*w;
                lg+=p.leftGrip*w;rg+=p.rightGrip*w;lt+=p.leftThumb*w;rt+=p.rightThumb*w;
                hips+=p.hips*w;ha+=p.hipsAngles*w;head+=(p.head+profile.emotions[i].headDegrees)*w;
                chest+=(p.chest+profile.emotions[i].chestDegrees)*w;gaze+=profile.emotions[i].gaze*w;
                leftFoot+=p.leftFoot*w;rightFoot+=p.rightFoot*w;la+=p.leftFootAngles*w;ra+=p.rightFootAngles*w;
            }
            float desiredThinking=state==BehaviorState.Thinking?1:weights[10]*gain;
            thinking=Mathf.Lerp(thinking,desiredThinking,1-Mathf.Exp(-8*dt));
            float flex=.5f+.5f*Mathf.Sin(time*2.5f);
            Vector4 baseL=Grip(.13f+flex*.06f),baseR=Grip(.17f+(1-flex)*.06f);
            float baseLT=.2f,baseRT=.25f;
            if(state==BehaviorState.Listening){baseL=Grip(.28f+flex*.1f);baseR=Grip(.2f);}
            if(state==BehaviorState.Speaking||state==BehaviorState.Researching)
            {
                float explain=.5f+.5f*Mathf.Sin(time*1.7f);
                baseL=new Vector4(.08f,.15f,.2f,.25f);
                baseR=Vector4.Lerp(Grip(.08f),new Vector4(.03f,.88f,.9f,.92f),explain);
                baseRT=explain*.85f;
                rig.OrientHand(false,new Vector3(.4f,.7f,.3f),Vector3.forward,1-total);
                rig.OrientHand(true,new Vector3(-.7f,.25f,.35f),Vector3.up,1-total);
            }
            rig.Hips(hips,ha);rig.Rotate(HumanBodyBones.Chest,chest);rig.Rotate(HumanBodyBones.Head,head);
            rig.Arm(true,rig.Hand(true)*(1-total)+l);rig.Arm(false,rig.Hand(false)*(1-total)+r);
            if(total>.001f){rig.OrientHand(true,lf,lp,total);rig.OrientHand(false,rf,rp,total);}
            LeftGrip=Vector4.Lerp(baseL,baseL*(1-total)+lg,profile.fingerActivity);
            RightGrip=Vector4.Lerp(baseR,baseR*(1-total)+rg,profile.fingerActivity);
            float hold=.92f+Mathf.Sin(time*1.2f)*.045f;
            RightGrip=Vector4.Lerp(RightGrip,Grip(hold),thinking);
            LeftGrip=Vector4.Lerp(LeftGrip,Grip(.4f+flex*.06f),thinking);
            rig.HandShape(true,LeftGrip,Mathf.Lerp(baseLT*(1-total)+lt,.3f,thinking));
            rig.HandShape(false,RightGrip,Mathf.Lerp(baseRT*(1-total)+rt,1,thinking));
            rig.ThinkingContact(profile.chinContactLocal,thinking);
            if(state==BehaviorState.Researching)gaze+=new Vector2(Mathf.Sin(time*.8f)*19,-7);
            if(state==BehaviorState.Thinking)gaze+=new Vector2(12+Mathf.Sin(time*.5f)*5,7);
            float entryLift=Mathf.Sin(Mathf.Clamp01(age/.7f)*Mathf.PI)*.075f;
            if(dominant==4||dominant==5||dominant==8||dominant==10)rightFoot.y+=entryLift*total;
            if(reaction=="surprise"){
                float accent=Mathf.Max(0,CompanionActingTiming.Phrase(reactionPhase));
                rig.Rotate(HumanBodyBones.Head,new Vector3(-15*accent,0,0));
                rig.Arm(true,Vector3.Lerp(rig.Hand(true),new Vector3(-.26f,1.34f,.22f),accent));
                rig.Arm(false,Vector3.Lerp(rig.Hand(false),new Vector3(.26f,1.34f,.22f),accent));
                rig.HandShape(true,Grip(.04f),.1f);rig.HandShape(false,Grip(.04f),.1f);
                rightFoot+=new Vector3(.025f,.075f,-.10f)*accent;
            }else if(reaction=="discovery"){
                float accent=Mathf.Max(0,CompanionActingTiming.Phrase(reactionPhase));
                rig.Arm(false,Vector3.Lerp(rig.Hand(false),new Vector3(.24f,1.43f,.2f),accent));
                rig.OrientHand(false,Vector3.up,Vector3.forward,accent);
                rig.HandShape(false,Vector4.Lerp(RightGrip,new Vector4(.02f,.97f,.97f,.97f),accent),accent);
            }else if(reaction=="nod")rig.Rotate(HumanBodyBones.Head,new Vector3(25*CompanionActingTiming.Phrase(reactionPhase),0,0));
            rig.MovingFeet(leftFoot*profile.stepGain,rightFoot*profile.stepGain,la*profile.stepGain,ra*profile.stepGain,true,profile.stepGain);
            return gaze;
        }
    }
}

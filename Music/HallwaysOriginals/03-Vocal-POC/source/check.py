import soundfile as sf, numpy as np, pyworld as pw, sys
sys.path.insert(0,'/home/claude/lab/voice'); import sing as S
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
fig,axs=plt.subplots(4,1,figsize=(14,11))
for ax,(f,notes,shift) in zip(axs,[('soul',S.LEAD,0),('crooner',S.LEAD,-12),('harmony',S.HARM,0),('harmony-low',S.HARM,-12)]):
    x,sr=sf.read(f'/home/claude/lab/voice/raw/{f}.wav'); f0,t=pw.harvest(x,sr,f0_floor=60,f0_ceil=1000,frame_period=5)
    errs=[]
    for s,d,m in S.onsets(notes,S.BPM):
        k=(t>=s+d*0.3)&(t<s+d*0.8)&(f0>0)
        if k.sum()<3: errs.append(None); continue
        errs.append(round(float(1200*np.log2(np.median(f0[k])/(440*2**((m+shift-69)/12))))))
        ax.hlines(m+shift,s,s+d,color='r',lw=3,alpha=.4)
    v=f0>0; ax.plot(t[v],69+12*np.log2(f0[v]/440),'.',ms=1.5); ax.set_title(f); ax.set_xlim(0,26)
    print(f,'cents:',errs)
plt.tight_layout(); plt.savefig('/home/claude/lab/voice/raw/pitch.png',dpi=70)

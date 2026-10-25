import sys, json, numpy as np
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
slug=sys.argv[1]; X=np.load(f'{slug}-stems.npy'); info=json.load(open(f'{slug}-info.json'))
SR=44100; fr=SR//20
fig,axs=plt.subplots(len(info['who']),1,figsize=(14,1.3*len(info['who'])),sharex=True)
for ax,w,x in zip(axs,info['who'],X):
    e=np.sqrt(np.mean(x[:len(x)//fr*fr].reshape(-1,fr,2)**2,axis=(1,2))); t=np.arange(len(e))/20
    ax.plot(t,20*np.log10(e+1e-9)); ax.set_ylim(-70,-5); ax.set_ylabel(w,rotation=0,ha='right'); ax.grid(alpha=.3)
full=X.sum(0); e=np.sqrt(np.mean(full[:len(full)//fr*fr].reshape(-1,fr,2)**2,axis=(1,2)))
print('full: peak dB',round(20*np.log10(np.abs(full).max()),1),' quietest 1s window dB',round(20*np.log10(np.convolve(e,np.ones(20)/20,'valid')[:-60].min()+1e-9),1))
plt.tight_layout(); plt.savefig(f'{slug}-env.png',dpi=60)

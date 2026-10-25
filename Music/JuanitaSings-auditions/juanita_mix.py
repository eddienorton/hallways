import importlib.util, numpy as np, os, subprocess, wave
from scipy import signal
spec=importlib.util.spec_from_file_location('j','juanita.py'); j=importlib.util.module_from_spec(spec); spec.loader.exec_module(j)
SR=j.SR; SPB=j.SPB; L=j.L
V=np.load('juanita-out/voices.npy'); names=open('juanita-out/voices.txt').read().split()
T=np.load('juanita-out/tinky.npy')
def rms_active(x):
    e=np.sqrt(np.mean(x**2,axis=1)); thr=np.percentile(e,60); a=x[e>thr*0.5] if (e>thr*0.5).any() else x
    return 20*np.log10(np.sqrt(np.mean(a**2))+1e-12)
def level(x,db): return x*10**((db-rms_active(x))/20)
def rmsdb(x): return 20*np.log10(np.sqrt(np.mean(x.astype(np.float64)**2))+1e-12)
bar=lambda b:int(round(b*4*SPB*SR))
def fades(x,fin=1.0,fout=4.0):
    x=x.copy(); n=int(fin*SR); x[:n]*=np.linspace(0,1,n)[:,None]**2; m=int(fout*SR); x[-m:]*=np.linspace(1,0,m)[:,None]**2; return x
os.makedirs('jprev',exist_ok=True)
def out(name,x):
    pk=np.abs(x).max()
    if pk>0.708: x=x*0.708/pk
    pcm=np.clip(x*32767,-32768,32767).astype(np.int16)
    with wave.open(f'jprev/{name}.wav','wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',f'jprev/{name}.wav','-c:a','aac','-b:a','256k',f'jprev/{name}.m4a'],check=True)
    print(name, round(len(x)/SR,1),'s', round(rmsdb(x),1),'dB')
voice={n:level(V[i],-21) for i,n in enumerate(names)}
tinky=T*10**((-25-rmsdb(T))/20)
# 1) each voice alone, at her desk: the first 16 bars (A A), close by, in the room
labels={'whistle-modelled':'A','hum-modelled':'B','library-whistle':'C','library-oohs':'D'}
for n in names:
    out(f'{labels[n]}-juanita-alone-{n}', fades(voice[n][:bar(16)+int(1.5*SR)],0.3,2.5))
# 2) the story, as the game would play it (a mock: the dialogue itself is not in it)
def far_version(x):
    lp=signal.butter(2,2600,fs=SR,output='sos'); y=signal.sosfilt(lp,x,axis=0)
    w=np.stack([signal.fftconvolve(y[:,c],j.IR[:,c])[:len(y)] for c in range(2)],axis=1)
    return 0.55*y+0.45*w
def ramp(total,pts):
    t=np.arange(total)/SR; xs=[p[0] for p in pts]; ys=[p[1] for p in pts]; return np.interp(t,xs,ys)
for n in ['whistle-modelled','hum-modelled']:
    total=int(150*SR)
    v=np.concatenate([voice[n],voice[n]])[:total]
    tk=np.concatenate([tinky,tinky])[:total]
    far=far_version(v)
    notes=[(b*SPB,(b+d)*SPB) for b,d,m in j.MELODY]+[((b+j.BEATS)*SPB,(b+d+j.BEATS)*SPB) for b,d,m in j.MELODY]
    # interrupted at ~19 s: she stops at the end of the note she is on
    stop=min(e for s,e in notes if e>=19.0)
    # she resumes at the first phrase after ~33 s (the timeline ran on, silent)
    starts=sorted([b*SPB for b in j.PHRASES]+[(b+j.BEATS)*SPB for b in j.PHRASES])
    resume=min(s for s in starts if s>=33.0)
    # Tinky joins at the first bar line after ~72 s
    tj=np.ceil(72.0/(4*SPB))*4*SPB
    singing=ramp(total,[(0,1),(stop,1),(stop+0.25,0),(resume-0.05,0),(resume,1),(150,1)])
    # where she is: far as the player comes in, near at the desk, farther as they leave; then the mix
    farness=ramp(total,[(0,1),(14,0.15),(stop,0.05),(resume,0.35),(60,0.75),(tj,0.85),(tj+5,0),(150,0)])
    gain=ramp(total,[(0,0.35),(14,0.9),(stop,1),(resume,0.8),(60,0.45),(tj,0.42),(tj+5,0.8),(150,0.8)])
    pan=ramp(total,[(0,0.35),(14,0.1),(resume,-0.2),(60,-0.45),(tj,-0.45),(tj+5,0),(150,0)])
    sv=((1-farness)[:,None]*v+farness[:,None]*far)*(singing*gain)[:,None]
    lg=np.sqrt(np.clip(1-pan,0,2)/2)[:,None]; rg=np.sqrt(np.clip(1+pan,0,2)/2)[:,None]
    sv=np.concatenate([sv[:,:1]*lg*np.sqrt(2),sv[:,1:]*rg*np.sqrt(2)],axis=1)
    tke=ramp(total,[(0,0),(tj,0),(tj+3,1),(150,1)])
    mix=sv+tk*(np.sin(tke*np.pi/2)**2)[:,None]
    out(f'{labels[n]}-the-story-{n}', fades(mix,0.5,6.0))
    open(f'jprev/{labels[n]}-story-cues.txt','w').write(f'stops {stop:.1f}s  resumes {resume:.1f}s  Tinky joins {tj:.1f}s\n')
    print(n,'stop',round(stop,1),'resume',round(resume,1),'tinky',round(tj,1))

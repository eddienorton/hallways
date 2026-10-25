import numpy as np, json, os, subprocess, wave
SR=44100
info=json.load(open('out1/info.json')); who=info['who']
LS=np.load('out1/loop.npy'); PS=np.load('out1/perf.npy')
def rms(x): return 20*np.log10(np.sqrt(np.mean(x.astype(np.float64)**2))+1e-12)
def active_rms(x):
    e=np.sqrt(np.mean(x.reshape(-1,2205,2)**2,axis=(1,2))) if len(x)%2205==0 else None
    return rms(x)
# the ensemble balance: each musician's level (dB RMS over the loop) -- melody on top, Tinky tucked in
target={'juanita':-19.0,'tinky':-25.5,'gloria':-21.5,'eileen':-22.5}
gain={w:10**((target[w]-rms(LS[i]))/20) for i,w in enumerate(who)}
L={w:LS[i]*gain[w] for i,w in enumerate(who)}; P={w:PS[i]*gain[w] for i,w in enumerate(who)}
OUT='deliver/01-The-Night-Shift-Waltz'; os.makedirs(OUT+'/loop',exist_ok=True); os.makedirs(OUT+'/performance-stems',exist_ok=True)
def finish(x, target_rms=-19.0, ceiling=-1.0, fin=0.02, fout=0.0):
    x=x*10**((target_rms-rms(x))/20)
    pk=np.abs(x).max(); lim=10**(ceiling/20)
    if pk>lim: x=x*lim/pk
    x=x.copy()
    if fin>0: n=int(fin*SR); x[:n]*=np.linspace(0,1,n)[:,None]
    if fout>0: n=int(fout*SR); x[-n:]*=np.linspace(1,0,n)[:,None]**1.5
    return x
def out(path,x):
    pcm=np.clip(x*32767,-32768,32767).astype(np.int16)
    tmp='/tmp/_mix.wav'
    with wave.open(tmp,'wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',tmp,'-c:a','aac','-b:a','256k',path],check=True)
    print(os.path.basename(path), f'{len(x)/SR:.1f}s', f'{rms(x):.1f} dB', f'peak {20*np.log10(np.abs(x).max()):.1f}')
# the finished performance
perf=sum(P.values()); out(OUT+'/00-finished-performance.m4a', finish(perf, -18.5, fout=0.0))
for i,w in enumerate(who):
    out(f'{OUT}/performance-stems/{w}.m4a', finish(P[w], -20, fout=0.0))
# the loop: each alone, combinations, all four (twice through: the loop point is heard)
combos=[(['juanita'],'01-juanita-alone'),(['tinky'],'02-tinky-alone'),(['gloria'],'03-gloria-alone'),(['eileen'],'04-eileen-alone'),
        (['juanita','gloria'],'05-juanita+gloria'),(['juanita','eileen'],'06-juanita+eileen'),(['tinky','gloria'],'07-tinky+gloria'),
        (['juanita','tinky','gloria'],'08-juanita+tinky+gloria'),(['tinky','gloria','eileen'],'09-tinky+gloria+eileen (no melody)'),
        (['juanita','gloria','eileen'],'10-juanita+gloria+eileen')]
for ws,name in combos:
    out(f'{OUT}/loop/{name}.m4a', finish(sum(L[w] for w in ws), -19.5, fout=2.5))
allfour=sum(L.values()); out(f'{OUT}/loop/11-all-four (loop twice).m4a', finish(np.concatenate([allfour,allfour]), -18.5, fout=3.0))
# seam check (the loop point): step across it vs typical steps
for w in who:
    x=L[w]; j=np.abs(x[0]-x[-1]).max(); typ=np.percentile(np.abs(np.diff(x[:,0])),99.9); print('seam',w,round(float(j),4),'typical',round(float(typ),4))
json.dump({k:float(20*np.log10(v)) for k,v in gain.items()},open(OUT+'/../_gains.json','w'))

import numpy as np, json, os, subprocess, wave, sys
SR=44100
info=json.load(open('out2/info.json')); who=info['who']
LS=np.load('out2/loop.npy'); PS=np.load('out2/perf.npy')
def rms(x): return 20*np.log10(np.sqrt(np.mean(x.astype(np.float64)**2))+1e-12)
target={'juanita':-20.0,'telephone':-21.5,'chair':-22.5,'pottle':-23.0,'camera':-24.0,'eileen':-24.0,'gloria':-21.0,'tinky':-23.0}
gain={w:10**((target[w]-rms(LS[i]))/20) for i,w in enumerate(who)}
L={w:LS[i]*gain[w] for i,w in enumerate(who)}; P={w:PS[i]*gain[w] for i,w in enumerate(who)}
OUT='deliver/02-Going-Up'; 
for d in ['loop','performance-stems']: os.makedirs(f'{OUT}/{d}',exist_ok=True)
def limit(x, ceiling=-1.0, look=0.004, release=0.12):
    """Look-ahead peak limiter: gain follows the 4 ms peak envelope down instantly, recovers over ~120 ms."""
    lim=10**(ceiling/20); hop=int(look*SR)
    n=len(x)//hop*hop; pk=np.abs(x[:n]).reshape(-1,hop,2).max(axis=(1,2))
    pk=np.maximum(pk, np.concatenate([pk[1:],pk[-1:]]))          # look ahead one block
    g=np.minimum(1.0, lim/np.maximum(pk,1e-9)); a=np.exp(-look/release); out=np.empty_like(g); cur=1.0
    for i,v in enumerate(g):
        cur = v if v<cur else cur*a+v*(1-a); out[i]=cur
    gs=np.interp(np.arange(len(x)), np.arange(len(out))*hop+hop/2, out)
    return x*gs[:,None]
def finish(x, target_rms=-19.0, ceiling=-1.0, fin=0.02, fout=0.0):
    x=x*10**((target_rms-rms(x))/20)
    x=limit(x, ceiling-0.3)
    pk=np.abs(x).max(); lim=10**(ceiling/20)
    if pk>lim: x=x*lim/pk
    x=x.copy()
    if fin>0: k=int(fin*SR); x[:k]*=np.linspace(0,1,k)[:,None]
    if fout>0: k=int(fout*SR); x[-k:]*=np.linspace(1,0,k)[:,None]**1.5
    return x
def out(path,x):
    pcm=np.clip(x*32767,-32768,32767).astype(np.int16)
    tmp='/tmp/_mix2.wav'
    with wave.open(tmp,'wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',tmp,'-c:a','aac','-b:a','256k',path],check=True)
    print(os.path.basename(path), f'{len(x)/SR:.1f}s', f'{rms(x):.1f} dB', f'peak {20*np.log10(np.abs(x).max()+1e-12):.1f}')
perf=sum(P.values()); out(OUT+'/00-finished-performance.m4a', finish(perf, -18.0, fout=0.0))
for w in who: out(f'{OUT}/performance-stems/{w}.m4a', finish(P[w], -20))
R=['gloria','tinky']
combos=[(['gloria','tinky'],'01-bass+drums'),
        (['gloria','tinky','eileen'],'02-bass+drums+piano (rhythm section)'),
        (['gloria','tinky','eileen','telephone'],'03-rhythm + Telephone sax'),
        (['gloria','tinky','eileen','juanita'],'04-rhythm + Juanita trumpet'),
        (['gloria','tinky','eileen','telephone','juanita'],'05-rhythm + sax + trumpet'),
        (['gloria','tinky','eileen','juanita','telephone','chair'],'06-rhythm + three horns'),
        (['gloria','tinky','eileen','camera','pottle'],'07-rhythm + vibes + clarinet (no brass)'),
        (['juanita','telephone','chair','pottle'],'08-the four horns alone'),
        (['gloria','tinky','juanita'],'09-trumpet, bass, drums (no piano)'),
        (['gloria','tinky','eileen','camera'],'10-rhythm + vibes')]
for ws,name in combos: out(f'{OUT}/loop/{name}.m4a', finish(sum(L[w] for w in ws), -19.5, fout=2.5))
for i,w in enumerate(who): out(f'{OUT}/loop/solo-{i+1}-{w}.m4a', finish(L[w], -20, fout=2.5))
full=sum(L.values()); out(f'{OUT}/loop/11-full band (loop twice).m4a', finish(np.concatenate([full,full]), -18.0, fout=3.0))
for w in who:
    x=L[w]; j=np.abs(x[0]-x[-1]).max(); typ=np.percentile(np.abs(np.diff(x[:,0])),99.9); print('seam',w,round(float(j),4),'typical',round(float(typ),4))
# activity per musician per 8 bars (how much each plays), for the README
bar=int(SR*60/168*4)
for i,w in enumerate(who):
    e=np.sqrt(np.mean(L[w].reshape(-1,bar*8 if len(L[w])%(bar*8)==0 else 1,2)**2,axis=(1,2))) if len(L[w])%(bar*8)==0 else None
    if e is not None: print(w,' '.join(f'{20*np.log10(v+1e-9):5.0f}' for v in e))
json.dump({k:float(20*np.log10(v)) for k,v in gain.items()},open('out2/gains.json','w'))
print('perf tail rms', rms(perf[-SR:]), 'perf len', len(perf)/SR)

import numpy as np, wave, subprocess, os, json, sys
SR=44100; BPM=84
st=np.load('out/stems.npy')        # juanita, tinky, flute
L=st.shape[1]
def rms(x): return 20*np.log10(np.sqrt(np.mean(x.astype(np.float64)**2))+1e-12)
target={'juanita':-23.0,'tinky':-25.0,'flute':-24.5}
names=['juanita','tinky','flute']
g={k: 10**((target[k]-rms(st[i]))/20) for i,k in enumerate(names)}
S={k: st[i]*g[k] for i,k in enumerate(names)}
full=S['juanita']+S['tinky']+S['flute']
# one scale for everything: the full band (looped twice, so the seam counts) peaks at -3 dBFS
scale=10**(-3/20)/np.abs(full).max()
S={k:v*scale for k,v in S.items()}
bar=lambda b: int(round(b*4*60/BPM*SR))
def fades(x, fin=2.0, fout=5.0):
    x=x.copy(); n=int(fin*SR); x[:n]*=np.linspace(0,1,n)[:,None]**2; m=int(fout*SR); x[-m:]*=np.linspace(1,0,m)[:,None]**2; return x
def env_at(total, start, secs=2.5):
    e=np.zeros(total); n=int(secs*SR); e[start:start+n]=np.sin(np.linspace(0,np.pi/2,n))**2; e[start+n:]=1; return e[:,None]
def out(name,x):
    pcm=np.clip(x*32767,-32768,32767).astype(np.int16)
    with wave.open(f'prev/{name}.wav','wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',f'prev/{name}.wav','-c:a','aac','-b:a','256k',f'prev/{name}.m4a'],check=True)
    return {'name':name,'seconds':round(len(x)/SR,1),'rms_dB':round(rms(x),1),'peak_dB':round(20*np.log10(np.abs(x).max()),1)}
os.makedirs('prev',exist_ok=True)
info=[]
info.append(out('1-juanita-alone',fades(S['juanita'])))
info.append(out('2-juanita-tinky',fades(S['juanita']+S['tinky'])))
info.append(out('3-juanita-tinky-flute',fades(S['juanita']+S['tinky']+S['flute'])))
# 4: as in the game -- Juanita, Tinky joins at bar 9, the flute at bar 33, on through the loop point to bar 24 of the next pass
total=L+bar(24)
loop=lambda x: np.concatenate([x,x])[:total]
prog=loop(S['juanita'])+loop(S['tinky'])*env_at(total,bar(8))+loop(S['flute'])*env_at(total,bar(32))
info.append(out('4-the-progression',fades(prog,fin=2.0,fout=7.0)))
# seam check: sample-to-sample jump across the loop point vs typical neighbouring jumps
for k in names:
    x=S[k]; j=np.abs(x[0]-x[-1]).max(); typ=np.percentile(np.abs(np.diff(x[:,0])),99.9)
    info.append({'seam':k,'jump':float(j),'p99.9_step':float(typ)})
print(json.dumps(info,indent=0)); print({k:round(float(20*np.log10(v*scale)),1) for k,v in g.items()})

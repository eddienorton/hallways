"""A guide track for recording Juanita's melody with a real voice (hum or whistle):
one bar of count-in clicks, then the whole loop: Tinky's part, the melody softly on
piano, and a quiet click on every beat. Sing/whistle along with headphones on."""
import importlib.util, numpy as np, subprocess, wave
spec=importlib.util.spec_from_file_location('j','juanita.py'); j=importlib.util.module_from_spec(spec); spec.loader.exec_module(j)
hb=j.hb; SR=j.SR; L=j.L; bar=int(round(4*j.SPB*SR))
mel=hb.Track('guide melody (piano)',0,5,vol=96,pan=64,reverb=25)
for b,d,m in j.MELODY: mel.add(b,d*0.95,m,72)
clk=hb.Track('click',0,9,vol=70,pan=64,reverb=0)
for k in range(j.BEATS): clk.add(k,0.1,76 if k%4==0 else 77,60 if k%4==0 else 40)
melx=hb.render(hb.midi_for([mel]),L); clkx=hb.render(hb.midi_for([clk]),L)
T=np.load('juanita-out/tinky.npy')
def lv(x,db): return x*10**((db-20*np.log10(np.sqrt(np.mean(x**2))+1e-12))/20)
body=lv(T,-26)+lv(melx,-24)+lv(clkx,-34)
cnt=hb.Track('count-in',0,9,vol=100,pan=64,reverb=0)
for k in range(4): cnt.add(k,0.1,76 if k==0 else 77,100)
cin=lv(hb.render(hb.midi_for([cnt]),bar),-24)
x=np.concatenate([cin,body]); x=x*0.7/np.abs(x).max()
pcm=np.clip(x*32767,-32768,32767).astype(np.int16)
with wave.open('jprev/E-recording-guide.wav','wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
subprocess.run(['ffmpeg','-y','-loglevel','error','-i','jprev/E-recording-guide.wav','-c:a','aac','-b:a','256k','jprev/E-recording-guide.m4a'],check=True)
print('guide', round(len(x)/SR,1),'s')

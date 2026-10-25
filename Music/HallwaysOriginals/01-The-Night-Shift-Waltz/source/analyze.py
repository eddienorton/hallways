import importlib.util, collections
spec=importlib.util.spec_from_file_location('o','original1.py'); o=importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
NN=['C','C#','D','Eb','E','F','F#','G','Ab','A','Bb','B']
def name(m): return NN[m%12]+str(m//12-1)
def check(P, beats, label):
    # sample every quarter beat: sounding notes per musician (not percussion)
    issues=collections.Counter(); examples={}
    who=['juanita','eileen','gloria','tinky']
    notes={w:[(s,s+d,m) for p in P[w] if p.channel!=9 for (s,d,m,v) in p.notes] for w in who}
    t=0.0
    while t<beats:
        sounding=[]
        for w in who:
            for s,e,m in notes[w]:
                # attack-weighted: only notes that started within the last 1.5 beats (decayed ones matter less)
                if s<=t<e and t-s<1.5: sounding.append((w,m,s))
        for i in range(len(sounding)):
            for k in range(i+1,len(sounding)):
                a,b=sounding[i],sounding[k]
                if a[0]==b[0]: continue
                iv=abs(a[1]-b[1])%12
                if iv==1 and abs(a[1]-b[1]) in (1,13):
                    bar=int(t//3)+1
                    key=(bar,a[0],name(a[1]),b[0],name(b[1]))
                    issues[key]+=1
        t+=0.25
    print(f'--- {label}: {len(issues)} half-step rubs (close, fresh attacks)')
    for (bar,w1,n1,w2,n2),c in sorted(issues.items()):
        print(f'  bar {bar:3d}: {w1} {n1} vs {w2} {n2}  x{c}')
LP,_,lb=o.build_loop(); check(LP,lb,'LOOP')
PP,_,pb=o.build_performance(); check(PP,pb,'PERFORMANCE')

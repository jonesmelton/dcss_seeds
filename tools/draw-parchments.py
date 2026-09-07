#!/usr/bin/env python3
"""Draw the three parchment tiles.

These are the only tiles in static/tiles/ that are not crawl's art. Crawl draws
parchments by spell *school* over three level tiers, which is 79 files that are
indistinguishable at the ~22px this page renders a tile; these encode the tier
alone, in crawl's parchment palette, using silhouette height, rule count, a wax
seal and a gilt band so the band survives the downscale.

Run from the repo root; writes static/tiles/items/parchment_{low,mid,high}.png.
"""
import zlib,struct
W=H=32
PAL={'.':None,
 'k':(0,0,0,255),'l':(252,236,189,255),'m':(222,197,155,255),'d':(191,165,121,255),
 's':(151,103,63,255),'D':(78,38,28,255),'r':(168,48,42,255),'R':(214,84,66,255),
 'g':(198,166,74,255),'G':(240,214,130,255),'i':(120,96,70,255)}
def blank(): return ['.'*W for _ in range(H)]
def put(rows,x,y,s):
    if y<0 or y>=H: return
    r=list(rows[y]); r[x:x+len(s)]=list(s); rows[y]=''.join(r)

L,R = 8,23           # narrower body: 16px wide, scroll-like
def roll(rows,y,face,gilt):
    put(rows,L-1,y,  'k'*(R-L+3))
    put(rows,L-2,y+1,'k'+'s'*(R-L+3)+'k')
    mid = ('G'+'g'*(R-L+1)+'G') if gilt else (face*(R-L+3))
    put(rows,L-2,y+2,'ks'+mid[1:-1]+'sk')
    put(rows,L-2,y+3,'k'+'s'*(R-L+3)+'k')
    put(rows,L-1,y+4,'k'*(R-L+3))

def body(rows,top,bot,lines,gilt=False,seal_at=None):
    roll(rows,top,'l',gilt)
    for y in range(top+5,bot):
        put(rows,L-1,y,'k'+'l'*(R-L+1)+'k')
        put(rows,R-1,y,'d'); put(rows,R,y,'d')
    for y,ln in lines:
        put(rows,L+2,y,'i'*ln); put(rows,L+2,y+1,'i'*ln)
    roll(rows,bot,'m',gilt)
    if seal_at is not None:
        cy=seal_at
        put(rows,14,cy,  'rRr'); put(rows,13,cy+1,'rRRRr'); put(rows,14,cy+2,'rrr')

def low():
    r=blank(); body(r,9,19,[(15,9)]); return r
def mid():
    r=blank(); body(r,6,22,[(12,11),(16,11)],seal_at=25); return r
def high():
    r=blank(); body(r,3,25,[(9,12),(13,12),(17,12),(21,12)],
                    gilt=True,seal_at=28); return r

def png(rows,path):
    raw=b''
    for row in rows:
        raw+=b'\x00'+b''.join(bytes(PAL[c] or (0,0,0,0)) for c in row)
    def ch(t,d):
        c=t+d; return struct.pack('>I',len(d))+c+struct.pack('>I',zlib.crc32(c)&0xffffffff)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'
        +ch(b'IHDR',struct.pack('>IIBBBBB',W,H,8,6,0,0,0))
        +ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))

for n,f in (('low',low),('mid',mid),('high',high)):
    png(f(),'static/tiles/items/parchment_%s.png'%n)
print("ok")

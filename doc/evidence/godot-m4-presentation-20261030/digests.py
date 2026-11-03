"""Trusted stat-bound digest reuse; never infer bytes from a filename or size."""
import hashlib,json
from pathlib import Path
TASK=Path('/data/quod-m4-vr-ca84d4f8-20261029')
ROOT=Path('/home/yan/src/quod_worktrees/pearl-stone')
SOURCES=[(TASK/'cache/coordinator-freeze39-hashes.json','0da99c3a4d53781b29f8e5c88025b0ccc4ae37a1d03757ae53cbf0c2ff7fc6e1'),(TASK/'cache/coordinator-additive40-hashes.json','ecb025071d2565cfaea0b64ea119307dedfa096c401663d5e4204f103f1d8959'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/physical-closure-hashes-49.json','5dd2cf6fbef43b2cb4cbe8b7cccb9955b1198f3bd1b8a5bda943757c2eb09028')]
SOURCES += [(TASK/'cache/coordinator-physical53-hashes.json','1b14b7d2bfb11713b74f76c9ed7db2b02e103226da2715673bcb10473bf6e043'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/case06-hashes-56.json','a1dd6c452230c81fb17cc342f496bb2eb2f6fed5c39a69c1075b97fef5981012'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/geometry-build-physical04-hashes-58.json','1fd03d1fb2d024972f837882764fb54c18b6ae17d9eb1070d097b3ed1c6e99a3')]
SOURCES += [(ROOT/'_build/godot-m4-r2-coordinator-20261029/case07-hashes-59.json','48adb618842bb5b9dd5b033e08f27ec8fc1ee4de664b0b530da452df68822875')]
SOURCES += [(ROOT/'_build/godot-m4-r2-coordinator-20261029/presentation-baseline-hashes-60.json','90983feb5195c168b6f58d16d53ebe0051d7e4776e3211c3f68020ddb1bf67e0'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/presentation-baseline-hashes-60-corrected.json','f3d88d273222956311de8fadd0b587a157d4c00ab2edb490dfad15803420661a')]
SOURCES += [(ROOT/'_build/godot-m4-r2-coordinator-20261029/presentation-candidates-hashes-61.json','bd1cf62efa1e0232b284617409dd6653010de6ac805065afe74ca5c33aea571c'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/presentation-candidates-hashes-61-corrected.json','c7e2df636d9870388479496f103fa6ab8a355f8980c5182dba94f586ea794ad6')]
def raw(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def key(p):
    s=Path(p).stat();return(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
class Digests:
    def __init__(self):
        self.values={};self.used={};self.hits=0;self.new=0;self.bytes=0
        for p,d in SOURCES:
            assert raw(p)==d,('trusted cache identity',str(p))
            data=json.loads(p.read_text())
            rows={tuple(r['stat_key']):r['sha256'] for r in data['records']} if 'records' in data else {tuple(map(int,k.split(','))):v for k,v in data.items()}
            for k,v in rows.items():
                assert k not in self.values or self.values[k]==v
                self.values[k]=v
    def h(self,p):
        k=key(p)
        if k in self.values:self.hits+=1;v=self.values[k]
        else:
            v=raw(p);assert key(p)==k;self.values[k]=v;self.new+=1;self.bytes+=k[2]
        self.used[k]=v;return v
    def link(self,p,q,digest):
        import os
        before=Path(p).stat();assert self.h(p)==digest
        os.link(p,q);a=Path(p).stat();b=Path(q).stat()
        assert (a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns,a.st_mode)==(before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_mode)
        assert (a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns,a.st_ctime_ns,a.st_mode)==(b.st_dev,b.st_ino,b.st_size,b.st_mtime_ns,b.st_ctime_ns,b.st_mode)
        assert a.st_nlink==before.st_nlink+1
        self.values[key(p)]=digest;self.used[key(p)]=digest
    def write(self,p):Path(p).write_text(json.dumps({'records':[{'stat_key':k,'sha256':v} for k,v in self.used.items()]})+'\n')


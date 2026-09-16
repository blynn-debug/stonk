"""Package raw research evidence in GitHub-sized, lossless ZIP archives."""
import hashlib,json,pathlib,zipfile
from collect import ROOT,RAW

def main():
    folder=ROOT/'evidence';folder.mkdir(exist_ok=True)
    groups=[];current=[];size=0
    for p in sorted(RAW.rglob('*')):
        if not p.is_file():continue
        if current and size+p.stat().st_size>100*1024**2:groups.append(current);current=[];size=0
        current.append(p);size+=p.stat().st_size
    if current:groups.append(current)
    manifest=[]
    for i,group in enumerate(groups,1):
        archive=folder/f'raw-{i:02}.zip';entries=[]
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for p in group:
                name=p.relative_to(RAW).as_posix();z.write(p,name);entries.append({'path':name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
        assert archive.stat().st_size<95*1024**2
        with zipfile.ZipFile(archive) as z:assert z.testzip() is None
        manifest.append({'archive':archive.name,'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'files':entries})
        print(archive.name,archive.stat().st_size,'bytes',len(group),'files',flush=True)
    (folder/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')

if __name__=='__main__':main()

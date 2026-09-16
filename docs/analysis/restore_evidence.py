"""Restore the exact raw data used by the report, validating checksums and paths."""
import hashlib,json,pathlib,zipfile

ROOT=pathlib.Path(__file__).resolve().parent
def main():
    raw=(ROOT/'raw').resolve();raw.mkdir(exist_ok=True)
    records=json.loads((ROOT/'evidence/manifest.json').read_text())
    for record in records:
        archive=ROOT/'evidence'/record['archive']
        assert hashlib.sha256(archive.read_bytes()).hexdigest()==record['sha256']
        with zipfile.ZipFile(archive) as z:
            for entry in record['files']:
                target=(raw/entry['path']).resolve()
                if not target.is_relative_to(raw):raise ValueError('Unsafe archive path')
                data=z.read(entry['path']);assert hashlib.sha256(data).hexdigest()==entry['sha256']
                target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    print('Raw evidence restored and verified.')

if __name__=='__main__':main()

#!/usr/bin/env python3
"""Exercise the ISO boundary without downloading images or running containers."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/bluebuild/iso.sh'
DIGEST = 'sha256:' + 'a' * 64
MOCK = '''#!/usr/bin/env python3
import json,os,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open('calls.jsonl','a') as f: f.write(json.dumps([name,*args])+'\\n')
if name=='cosign':
 if os.environ.get('BAD_SIGNATURE'): sys.exit(1)
 print('[]')
elif name=='skopeo':
 if args[0]=='list-tags': print('{"Tags": ["bluefin-generic"]}')
 elif args[0]=='inspect':
  digest=os.environ['DIGEST']
  if os.environ.get('MOVED_CHANNEL') and args[-1].endswith(':bluefin-generic'): digest='sha256:'+'b'*64
  if '--format' in args: print(digest)
  else: print(json.dumps({'Digest':digest,'Labels':{'io.finite.profile':'bluefin-generic'}}))
elif name=='sudo':
 assert args[0:2]==['bluebuild','generate-iso']
 assert args[args.index('--variant')+1]=='kinoite'
 assert args[-2]=='image' and ':iso-' in args[-1] and '@' not in args[-1]
 path=pathlib.Path(args[args.index('--output-dir')+1])/args[args.index('--iso-name')+1]
 path.write_bytes(b'fixture ISO')
'''

class IsoBoundary(unittest.TestCase):
    def run_iso(self, **extra):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        bindir = root / 'bin'
        bindir.mkdir()
        for name in ['cosign','skopeo','sudo']:
            tool = bindir / name
            tool.write_text(MOCK.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
            tool.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir)+':'+os.environ['PATH'], DIGEST=DIGEST,
                   GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2', **extra)
        result = subprocess.run(['bash',str(SCRIPT),'bluefin-generic',DIGEST],cwd=root,env=env,capture_output=True,text=True)
        self.assertTrue((root/'calls.jsonl').exists(), result.stderr)
        calls=[json.loads(l) for l in (root/'calls.jsonl').read_text().splitlines()]
        return root,result,calls

    def test_verified_digest_uses_unique_tag_and_records_channel(self):
        root,result,calls=self.run_iso()
        self.assertEqual(result.returncode,0,result.stderr)
        record=json.loads((root/'.bluebuild/iso/installation.json').read_text())
        self.assertEqual(record['image'],'ghcr.io/closure-labs/finbox@'+DIGEST)
        self.assertRegex(record['installationTag'],r':iso-123-2-[a-f0-9-]{36}$')
        self.assertEqual(record['updateChannel'],'ghcr.io/closure-labs/finbox:bluefin-generic')
        copy=next(c for c in calls if c[:2]==['skopeo','copy'])
        self.assertIn('--preserve-digests',copy)
        self.assertIn('--all',copy)
        self.assertTrue((root/'.bluebuild/iso/SHA256SUMS').is_file())

    def test_bad_signature_never_copies_or_builds(self):
        _,result,calls=self.run_iso(BAD_SIGNATURE='1')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:2]==['skopeo','copy'] or c[0]=='sudo' for c in calls))

    def test_moved_channel_never_copies_or_builds(self):
        _,result,calls=self.run_iso(MOVED_CHANNEL='1')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:2]==['skopeo','copy'] or c[0]=='sudo' for c in calls))

if __name__=='__main__': unittest.main()

#!/usr/bin/env python3
"""Offline release regression checks; never creates a real GitHub release."""
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
clean = {k: v for k, v in os.environ.items() if k not in ('GITHUB_RUN_NUMBER', 'GITHUB_OUTPUT')}
for run in ['1', '2', '150']:
    result = subprocess.run(['python3', str(root/'scripts/release-version.py')],
                            env={**clean, 'GITHUB_RUN_NUMBER': run}, capture_output=True, text=True, check=True)
    base = list(map(int, (root/'VERSION').read_text().strip().split('.')))
    assert f'version={base[0]}.{base[1]}.{base[2]+int(run)}' in result.stdout
    rerun = subprocess.run(['python3', str(root/'scripts/release-version.py')],
                          env={**clean, 'GITHUB_RUN_NUMBER': run, 'GITHUB_RUN_ATTEMPT': '2'},
                          capture_output=True, text=True, check=True)
    assert rerun.stdout == result.stdout

fake_gh = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
p = Path('gh-state.json')
s = json.loads(p.read_text()) if p.exists() else {'id': 1, 'draft': True, 'assets': []}
with open('calls.txt', 'a') as out: out.write(' '.join(args)+'\\n')
if args[:3] == ['api','--method','PATCH']:
    assert len(s['assets']) == 4
    assert 'draft=false' in args and 'prerelease=false' in args
    assert 'make_latest=legacy' in args
    s['draft'] = False
    p.write_text(json.dumps(s))
    print(json.dumps(s))
elif args[0] == 'api':
    if '/releases/tags/' in args[1]:
        if p.exists() and not s['draft']: print(json.dumps(s))
        else: print('HTTP 404', file=sys.stderr); sys.exit(1)
    elif '/releases?per_page=100' in args[1]:
        assert '--paginate' in args and '--slurp' in args
        print(json.dumps([[s] if p.exists() else []]))
    elif '/commits/' in args[1]:
        if s['draft']: print('HTTP 404', file=sys.stderr); sys.exit(1)
        print(s.get('target_commitish', os.environ['GITHUB_SHA']))
    elif '/releases/latest' in args[1]: print('v9.0.0')
elif args[:2] == ['release','create']:
    assert not p.exists(), 'Cannot create a duplicate draft'
    s['tag_name'] = args[2]
    s['target_commitish'] = args[args.index('--target')+1]
    s['html_url'] = 'https://example.test/release'
    p.write_text(json.dumps(s))
elif args[:2] == ['release','upload']:
    s['assets'] = [{'name': Path(a).name} for a in args[3:] if Path(a).is_file()]
    p.write_text(json.dumps(s))
elif args[:2] == ['release','view']: print(s['html_url'])
else: sys.exit(2)
'''
with tempfile.TemporaryDirectory() as temp:
    work = pathlib.Path(temp)
    bin_dir = work/'bin'; bin_dir.mkdir()
    gh = bin_dir/'gh'; gh.write_text(fake_gh); gh.chmod(0o755)
    assets = work/'dist/releases'; assets.mkdir(parents=True)
    version = '1.0.2'; sha = 'a'*40
    for ext in ['zip', 'dmg']:
        (assets/f'Power-View-{version}-macOS-arm64.{ext}').write_bytes(b'package')
    metadata = {'version':version, 'commit':sha, 'architecture':'arm64',
                'signing':'developer-id', 'notarized':True, 'publisher':'Test Publisher',
                'notarization':{'app':'app-request', 'dmg':'dmg-request'}}
    (assets/'build-info.json').write_text(json.dumps(metadata))
    sums = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(assets.iterdir())]
    (assets/'SHA256SUMS.txt').write_text(''.join(sums))
    env = {**clean, 'PATH':str(bin_dir)+os.pathsep+os.environ['PATH'], 'GH_REPO':'owner/project',
           'GITHUB_SHA':sha, 'APP_VERSION':version}
    def publish(ok=True):
        p = subprocess.run(['python3', str(root/'scripts/publish-release.py')], cwd=work,
                           env=env, capture_output=True, text=True)
        assert (p.returncode == 0) == ok, p.stderr
        return p
    for invalid in [dict(metadata, signing='ad-hoc'), dict(metadata, notarized=False),
                    dict(metadata, notarized='true'), dict(metadata, notarization={'app':'only-app'})]:
        (assets/'build-info.json').write_text(json.dumps(invalid))
        publish(ok=False)
        assert not (work/'calls.txt').exists()  # Unsigned/unnotarized assets never touch GitHub.
    (assets/'build-info.json').write_text(json.dumps(metadata))
    publish()
    assert not json.loads((work/'gh-state.json').read_text())['draft']
    (work/'calls.txt').write_text('')
    publish()
    assert 'release upload' not in (work/'calls.txt').read_text()  # Published reruns are immutable.
    saved = json.loads((work/'gh-state.json').read_text())
    saved['draft'] = True; saved['assets'] = []
    (work/'gh-state.json').write_text(json.dumps(saved))
    publish()  # Recover a partial draft.
    saved['target_commitish'] = 'b'*40
    (work/'gh-state.json').write_text(json.dumps(saved))
    publish(ok=False)  # A version cannot change commits.
    saved['target_commitish'] = sha
    (work/'gh-state.json').write_text(json.dumps(saved))
    (assets/f'Power-View-{version}-macOS-arm64.zip').write_bytes(b'tampered')
    (work/'calls.txt').write_text('')
    publish(ok=False)
    assert not (work/'calls.txt').read_text()  # Fail before any API mutations.
print('Passed release checks: signing/notarization gate, versioning, reruns, draft recovery, exact commit, latest ordering, checksum rejection.')

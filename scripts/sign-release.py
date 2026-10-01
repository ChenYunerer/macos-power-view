#!/usr/bin/env python3
"""Sign and notarize app + DMG in an isolated, disposable keychain."""
import base64
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import signal
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
os.chdir(ROOT)


def run(*args, sensitive=False):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        if not sensitive:
            print(result.stdout)
            print(result.stderr)
        raise SystemExit(f'{pathlib.Path(args[0]).name} failed (exit {result.returncode})')
    return result.stdout


required = ['APPLE_CERTIFICATE_BASE64', 'APPLE_CERTIFICATE_PASSWORD',
            'APPLE_NOTARY_KEY_BASE64', 'APPLE_NOTARY_KEY_ID', 'APPLE_NOTARY_ISSUER_ID']
if any(not os.environ.get(name) for name in required):
    raise SystemExit('Signing credentials missing; refusing to publish an unsigned release')
# Keep credentials out of subprocess environments and logs.
credentials = {name: os.environ.pop(name) for name in required}
work = pathlib.Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'power-view-signing'
work.mkdir(mode=0o700)  # Refuse to reuse an unexpected preexisting directory.
keychain = work / 'signing.keychain-db'


def interrupted(*_):
    raise SystemExit('Signing interrupted')


signal.signal(signal.SIGTERM, interrupted)

try:
    certificate = work / 'identity.p12'
    api_key = work / 'notary.p8'
    for path, value in [(certificate, credentials['APPLE_CERTIFICATE_BASE64']),
                        (api_key, credentials['APPLE_NOTARY_KEY_BASE64'])]:
        path.write_bytes(base64.b64decode(value, validate=True))
        path.chmod(0o600)
    password = secrets.token_urlsafe(32)
    run('security', 'create-keychain', '-p', password, str(keychain), sensitive=True)
    run('security', 'set-keychain-settings', '-lut', '3600', str(keychain))
    run('security', 'unlock-keychain', '-p', password, str(keychain), sensitive=True)
    run('security', 'import', str(certificate), '-P', credentials['APPLE_CERTIFICATE_PASSWORD'],
        '-k', str(keychain), '-T', '/usr/bin/codesign', sensitive=True)
    run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
        '-s', '-k', password, str(keychain), sensitive=True)
    certificate.unlink()
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain))
    matches = re.findall(r'([A-Fa-f0-9]{40}) "(Developer ID Application: [^\n"]+ \(([A-Z0-9]{10})\))"', identities)
    if len(matches) != 1:
        raise SystemExit('Expected one valid Developer ID Application identity')
    identity, publisher, team = matches[0]
    print(f'Signing as {publisher}', flush=True)

    app = ROOT / 'dist/Power View.app'
    helper = app / 'Contents/Helpers/PowerFanHelper'
    for target in [helper, app]:
        run('codesign', '--force', '--sign', identity, '--keychain', str(keychain),
            '--options', 'runtime', '--timestamp', str(target))
    requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{team}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    for target in [helper, app]:
        run('codesign', '--verify', '--strict', '-R', requirement, str(target))
    run('codesign', '--verify', '--deep', '--strict', str(app))

    auth = ['--key', str(api_key), '--key-id', credentials['APPLE_NOTARY_KEY_ID'],
            '--issuer', credentials['APPLE_NOTARY_ISSUER_ID']]
    logs = ROOT / '.build/notarization'
    logs.mkdir(parents=True, exist_ok=True)

    def notarize(path, label):
        print(f'Submitting {label} to Apple...', flush=True)
        # Save the request ID before waiting, including when Apple takes longer
        # than our deadline. A non-Accepted result never reaches publication.
        submitted = json.loads(run('xcrun', 'notarytool', 'submit', str(path),
                                   *auth, '--output-format', 'json'))
        request_id = submitted['id']
        (logs / f'{label}-submission.json').write_text(json.dumps(submitted, indent=2))
        result = subprocess.run(['xcrun', 'notarytool', 'wait', request_id,
                                 *auth, '--timeout', '20m', '--output-format', 'json'],
                                capture_output=True, text=True)
        (logs / f'{label}-result.json').write_text(result.stdout)
        try:
            status = json.loads(result.stdout).get('status')
        except json.JSONDecodeError:
            status = None
        if result.returncode or status != 'Accepted':
            log = subprocess.run(['xcrun', 'notarytool', 'log', request_id, *auth],
                                 capture_output=True, text=True)
            (logs / f'{label}-log.json').write_text(log.stdout)
            print(log.stdout)
            raise SystemExit(f'{label} notarization not accepted: {status}; request {request_id}')
        print(f'{label}: Accepted ({request_id})', flush=True)
        return request_id

    upload = work / 'Power-View.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(upload))
    app_request = notarize(upload, 'app')
    run('xcrun', 'stapler', 'staple', str(app))
    run('xcrun', 'stapler', 'validate', str(app))
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))

    # ZIP now contains the stapled app; package the same app into the DMG.
    run('bash', 'scripts/package-release.sh')
    output = ROOT / 'dist/releases'
    metadata_path = output / 'build-info.json'
    metadata = json.loads(metadata_path.read_text())
    basename = f'Power-View-{metadata["version"]}-macOS-arm64'
    dmg = output / f'{basename}.dmg'
    run('codesign', '--force', '--sign', identity, '--keychain', str(keychain), '--timestamp', str(dmg))
    dmg_request = notarize(dmg, 'dmg')
    run('xcrun', 'stapler', 'staple', str(dmg))
    run('xcrun', 'stapler', 'validate', str(dmg))
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', str(dmg))
    metadata.update(signing='developer-id', notarized=True, team_id=team,
                    publisher=publisher, notarization={'app': app_request, 'dmg': dmg_request})
    metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
    assets = [output / f'{basename}.zip', dmg, metadata_path]
    (output / 'SHA256SUMS.txt').write_text(''.join(
        f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in assets))
    print('Signed, notarized, stapled and verified app + DMG.', flush=True)
finally:
    if keychain.exists():
        subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)
    shutil.rmtree(work)

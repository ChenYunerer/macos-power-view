#!/usr/bin/env python3
"""Publish tested artifacts against the exact commit, using a recoverable draft."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile


def gh(*args, check=True):
    result = subprocess.run(['gh', *args], text=True, capture_output=True)
    if check and result.returncode:
        raise SystemExit(result.stderr)
    return result


repo = os.environ['GH_REPO']
sha = os.environ['GITHUB_SHA']
version = os.environ['APP_VERSION']
tag = f'v{version}'
if not re.fullmatch(r'[\w.-]+/[\w.-]+', repo) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('Invalid repository or version')
if not re.fullmatch(r'[a-f0-9]{40}', sha):
    raise SystemExit('Expected a full commit SHA')
folder = pathlib.Path('dist/releases')
basename = f'Power-View-{version}-macOS-arm64'
assets = [folder / f'{basename}.zip', folder / f'{basename}.dmg',
          folder / 'build-info.json', folder / 'SHA256SUMS.txt']
if not all(path.is_file() for path in assets):
    raise SystemExit('Missing release assets')
metadata = json.loads((folder / 'build-info.json').read_text())
if metadata['version'] != version or metadata['commit'] != sha or metadata['architecture'] != 'arm64':
    raise SystemExit('Artifact provenance does not match this workflow run')
if metadata.get('signing') != 'developer-id' or metadata.get('notarized') is not True:
    raise SystemExit('Formal releases require Developer ID signing and Apple notarization')
if not all(metadata.get('notarization', {}).get(kind) for kind in ('app', 'dmg')):
    raise SystemExit('Missing app or DMG notarization request ID')
checked = set()
for line in (folder / 'SHA256SUMS.txt').read_text().splitlines():
    expected, name = line.split(maxsplit=1)
    path = folder / name.lstrip('*')
    if path not in assets or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Invalid asset checksum: {name}')
    checked.add(path)
if checked != set(assets[:-1]):
    raise SystemExit('Checksum manifest must cover every release asset')

def find_release():
    result = gh('api', f'repos/{repo}/releases/tags/{tag}', check=False)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if '404' not in result.stderr:
        raise SystemExit(result.stderr)
    # The tag endpoint only returns published releases. The authenticated list
    # includes drafts, including drafts whose Git tag has not been created yet.
    pages = json.loads(gh('api', f'repos/{repo}/releases?per_page=100',
                          '--paginate', '--slurp').stdout)
    return next((item for page in pages for item in page if item['tag_name'] == tag), None)


release = find_release()
if release is not None:
    # Never reuse a version for a different commit or silently overwrite a stable release.
    ref = gh('api', f'repos/{repo}/commits/{tag}', '--jq', '.sha', check=False)
    target = ref.stdout.strip() if ref.returncode == 0 else release['target_commitish']
    if target != sha:
        raise SystemExit(f'{tag} already belongs to a different commit')
    if not release['draft']:
        if not {p.name for p in assets}.issubset({a['name'] for a in release['assets']}):
            raise SystemExit('Published release has missing assets; refusing to silently overwrite it')
        print(f'Already published: {release["html_url"]}')
        raise SystemExit(0)
else:
    notes = f'''Apple Silicon · macOS 14 及以上

- 提交：{sha}
- 下载 DMG 后将 Power View 拖入 Applications，或解压 ZIP 使用。
- SHA256SUMS.txt 可用于校验下载文件。
- 此版本已使用 Developer ID 签名并通过 Apple 公证，应用与 DMG 均已附加公证票据。
- 签名身份：{metadata['publisher']}。
- 风扇手动控制需要管理员授权；支持的 Apple Silicon 机型可按风扇独立设置目标转速、恢复系统自动。
'''
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md') as note:
        note.write(notes)
        note.flush()
        gh('release', 'create', tag, '--repo', repo, '--target', sha, '--draft',
           '--title', f'Power View {version}', '--notes-file', note.name)

gh('release', 'upload', tag, *map(str, assets), '--repo', repo, '--clobber')
# Publish in one server-side update. GitHub chooses Latest by semantic version,
# so parallel builds finishing out of order cannot force an older release Latest.
release = find_release()
if release is None:
    raise SystemExit('Uploaded release could not be found; rerun to resume the draft')
result = gh('api', '--method', 'PATCH', f'repos/{repo}/releases/{release["id"]}',
            '-F', 'draft=false', '-F', 'prerelease=false', '-f', 'make_latest=legacy')
print(json.loads(result.stdout)['html_url'])

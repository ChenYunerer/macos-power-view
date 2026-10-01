#!/usr/bin/env python3
"""Deterministic version for each Actions run; reruns reuse the same version."""
import os
import pathlib
import re

base = pathlib.Path(__file__).resolve().parents[1].joinpath('VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', base):
    raise SystemExit('VERSION must contain major.minor.patch')
run = os.environ.get('GITHUB_RUN_NUMBER')
version = base
if run:
    if not run.isdecimal() or int(run) < 1:
        raise SystemExit('Invalid GITHUB_RUN_NUMBER')
    major, minor, patch = map(int, base.split('.'))
    version = f'{major}.{minor}.{patch + int(run)}'
values = {'version': version, 'build_number': run or '1', 'tag': f'v{version}'}
for key, value in values.items():
    print(f'{key}={value}')
if output := os.environ.get('GITHUB_OUTPUT'):
    with open(output, 'a') as handle:
        handle.writelines(f'{key}={value}\n' for key, value in values.items())

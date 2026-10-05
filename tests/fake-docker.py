#!/usr/bin/env python3
"""Double de l'API CLI Docker : aucun accès au daemon ou au réseau."""
import json
import os
import sys
from pathlib import Path

state = json.loads(Path(os.environ['FAKE_DOCKER_STATE']).read_text())
args = sys.argv[1:]
with open(os.environ['FAKE_DOCKER_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
if state.get('offline'):
    sys.exit(1)
containers = state.get('containers', [])

def find(value):
    return next((c for c in containers if c['Id'].startswith(value) or c['Name'].lstrip('/') == value), None)

if args[0] == 'ps':
    selected = containers if '-a' in args or '-aq' in args else [c for c in containers if c['State']['Status'] == 'running']
    if '-aq' in args:
        print('\n'.join(c['Id'] for c in selected))
    elif '--format' in args and args[args.index('--format') + 1] == '{{json .}}':
        for c in selected:
            print(json.dumps({'ID': c['Id'][:12], 'Names': c['Name'].lstrip('/'), 'Image': c['Config']['Image'], 'State': c['State']['Status'], 'Status': 'test', 'Labels': ''}))
    else:
        print('\n'.join(c['Name'].lstrip('/') for c in selected))
elif args[0] == 'inspect':
    if '--format' in args:
        fmt = args[args.index('--format') + 1]
        c = find(args[-1])
        if not c:
            sys.exit(1)
        if fmt == '{{.Name}}':
            print(c['Name'])
        elif fmt == '{{.State.Status}}':
            print(c['State']['Status'])
        elif 'index .Config.Labels' in fmt:
            label = fmt.split('"')[1]
            print(c['Config'].get('Labels', {}).get(label, ''))
        else:
            sys.exit('Format non simulé : ' + fmt)
    else:
        selected = [find(name) for name in args[1:]]
        if not all(selected):
            sys.exit(1)
        print(json.dumps(selected))
elif args[0] in ('image', 'volume', 'network') and args[1] == 'inspect':
    key = {'image': 'images', 'volume': 'volumes', 'network': 'networks'}[args[0]]
    sys.exit(0 if args[-1] in state.get(key, []) else 1)
elif args[0] == 'exec' and args[2] == 'cat':
    c = find(args[1])
    if not c or 'heartbeat' not in c:
        sys.exit(1)
    print(c['heartbeat'])
elif args[0] == 'create':
    sys.exit(1 if state.get('fail_create') else 0)
elif args[0] == 'rm':
    state['containers'] = [c for c in containers if c['Name'].lstrip('/') != args[-1]]
    Path(os.environ['FAKE_DOCKER_STATE']).write_text(json.dumps(state))
    sys.exit(0)
elif args[0] in ('restart', 'rm', 'start') or args[:2] == ['network', 'connect']:
    sys.exit(0)
else:
    sys.exit('Commande non simulée : ' + repr(args))

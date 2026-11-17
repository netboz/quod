#!/usr/bin/env python3
"""One-shot operator for the current seven-foundation recipe; no retries or replay."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time

BASE = Path('/home/yan/src/quod_worktrees/pearl-stone/_build/refound-280/deployment')
ADDR = 'http://192.168.1.10:4646'
BEAM = BASE / 'quod_foundation_operator.beam'
ALLOC = (BASE / 'founder-allocation-id').read_text().strip()
ANCHORS = BASE / 'foundation-anchors.json'


def save_new(path, value, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, 'w') as handle:
        json.dump(value, handle, indent=2)
        handle.write('\n')


def evaluate(label, expression):
    outer = 'binary_to_list(base64:encode(iolist_to_binary(json:encode(begin ' + expression + ' end)))).'
    command = ['nomad', 'alloc', 'exec', '-i=false', '-t=false', '-address=' + ADDR,
               '-task', 'quod', ALLOC, '/opt/quod/bin/quod', 'eval', outer]
    save_new(BASE / (label + '.intent.json'), {'allocation': ALLOC, 'expression': expression,
                                               'command_argv': command})
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    save_new(BASE / (label + '.exit.json'), {'exit': result.returncode,
                                             'seconds': time.monotonic() - started})
    (BASE / (label + '.stdout')).write_text(result.stdout)
    (BASE / (label + '.stderr')).write_text(result.stderr)
    if result.returncode:
        print('FAILED', label, 'exit', result.returncode, file=sys.stderr)
        print(result.stderr[-1200:], file=sys.stderr)
        raise SystemExit(result.returncode)
    wire = json.loads(result.stdout)
    if isinstance(wire, list):
        wire = bytes(wire).decode('ascii')
    value = json.loads(base64.b64decode(wire, validate=True))
    save_new(BASE / (label + '.json'), value)
    print(label, json.dumps(value, sort_keys=True), flush=True)
    return value


def q(text):
    return json.dumps(text)


def b(text):
    return '<<' + q(text) + '>>'


def hexbin(hex_value):
    assert re.fullmatch('[0-9A-F]{64}', hex_value)
    return 'binary:decode_hex(' + b(hex_value) + ')'


def anchors():
    return json.loads(ANCHORS.read_text()) if ANCHORS.exists() else {}


def pin(name):
    return hexbin(anchors()[name])


def source(name):
    return 'filename:join([code:priv_dir(quod),"ontologies",' + q(name) + '])'


def source_bytes(name, var):
    return '{ok,' + var + '}=file:read_file(' + source(name) + ')'


def found(name, files, terms, modules, pre=''):
    ns = 'quod:' + name
    files_text = '[' + ','.join(q(f) for f in files) + ']'
    modules_text = '[' + ','.join(modules) + ']'
    expression = (pre + ',' if pre else '') + 'quod_foundation_operator:found(' + b(ns) + ',' + files_text + ',[' + ','.join(terms) + '],' + modules_text + ')'
    value = evaluate('found-' + name, expression)
    found_anchor = value['anchor']
    assert re.fullmatch('[0-9A-F]{64}', found_anchor)
    current = anchors()
    assert name not in current
    current[name] = found_anchor
    ANCHORS.write_text(json.dumps(current, indent=2) + '\n')
    return value


def publish(name, creation=False):
    return evaluate('publish-' + name,
                    'quod_foundation_operator:publish(' + b('quod:' + name) + ',' + pin(name) + ',' + ('true' if creation else 'false') + ')')


def pin_term(predicate, name):
    return '{' + predicate + ',' + b('quod:' + name) + ',' + pin(name) + '}'


def main():
    phase = sys.argv[1]
    if phase == 'load':
        data = BEAM.read_bytes()
        digest = hashlib.sha256(data).hexdigest().upper()
        payload = base64.b64encode(data).decode('ascii')
        evaluate('load-helper', '{module,quod_foundation_operator}=code:load_binary(quod_foundation_operator,' + q(digest) + ',base64:decode(' + b(payload) + ')),#{loaded=>true}')
    elif phase == 'root':
        evaluate('root-identity', '{ok,Network}=quod_ontology:network_identity(),#{root_anchor=>binary:encode_hex(quod_simplex:genesis_hash(' + b('quod:root') + ')),network=>binary:encode_hex(Network)}')
    elif phase == 'node':
        found('node', ['quod_node.pl'], ['{node_identity_template,NodeTemplate}'],
              ['quod_agent_predicates'], source_bytes('node_instance.pl', 'NodeTemplate'))
        publish('node', True)
        evaluate('node-enrollment', 'quod_foundation_operator:enrolled_node()')
    elif phase == 'agent':
        found('agent', ['quod_agent.pl'], [], ['quod_agent_predicates'])
        publish('agent')
    elif phase == 'gui':
        found('gui', ['quod_gui.pl', 'gui_measure.pl', 'gui_scene.pl', 'gui_tools.pl'], [],
              ['quod_agent_predicates', 'quod_gui_predicates'])
        publish('gui')
    elif phase == 'controllers':
        found('controllers', ['quod_controllers.pl'], [pin_term('gui_vocabulary', 'gui')],
              ['quod_agent_predicates'])
        publish('controllers')
    elif phase == 'space':
        gui_pins = [pin_term(p, 'gui') for p in ['gui_vocabulary', 'measure_vocabulary', 'rendering_vocabulary', 'modelling_vocabulary']]
        terms = gui_pins + ['space_foundation', "{acl_sovereign,{':',quod,space}}", '{space_template_hash,crypto:hash(sha256,SpaceTemplate)}']
        found('space', ['quod_space.pl'], terms, ['quod_agent_predicates'],
              source_bytes('quod_space.pl', 'SpaceTemplate'))
        publish('space')
    elif phase == 'user':
        gui_pins = [pin_term(p, 'gui') for p in ['gui_vocabulary', 'measure_vocabulary', 'rendering_vocabulary', 'modelling_vocabulary']]
        pins = gui_pins + [pin_term('agent_vocabulary', 'agent'), pin_term('controllers_vocabulary', 'controllers'),
                           pin_term('space_vocabulary', 'space'), '{space_source_digest,crypto:hash(sha256,SpaceTemplate)}']
        components = ['user_instance.pl', 'agent_instance.pl', 'quod_space.pl', 'gui_instance.pl']
        frozen = ['{user_source_component,' + b(f) + ',crypto:hash(sha256,' + v + ')}'
                  for f, v in zip(components, ['C0', 'C1', 'C2', 'C3'])]
        pre = ','.join(source_bytes(f, v) for f, v in zip(components, ['C0', 'C1', 'C2', 'C3']))
        terms = pins + frozen + ['{user_source_directory,list_to_binary(filename:join(code:priv_dir(quod),"ontologies"))}',
                                  '{signup_host,quod_foundation_operator:node_ref()}']
        found('user', ['quod_user.pl'], terms, ['quod_agent_predicates'], pre + ',' + source_bytes('quod_space.pl', 'SpaceTemplate'))
        evaluate('root-admin', 'quod_foundation_operator:root_admin()')
    elif phase == 'user-register':
        operation = secrets.token_bytes(32).hex().upper()
        save_new(BASE / 'user-registration-operation.json', {'operation': operation})
        signed = evaluate('user-registration-signed',
                          'quod_foundation_operator:signed_user_registration(' + pin('user') + ',' + hexbin(operation) + ')')
        save_new(BASE / 'user-registration-original.json', signed)
        submitted = evaluate('user-registration-submitted',
                             'quod_foundation_operator:submit_saved(' + b(signed['request']) + ',' + b(signed['signature']) + ')')
        if submitted['status'] != 'committed':
            raise SystemExit('user registration did not return a committed result; resolve its saved original operation before proceeding')
    elif phase == 'catalogue':
        evaluate('final-catalogue', 'quod_foundation_operator:catalogue()')
    else:
        raise SystemExit('unknown phase')


if __name__ == '__main__':
    main()

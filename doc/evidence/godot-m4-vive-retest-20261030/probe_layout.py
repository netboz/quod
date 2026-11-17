"""Ask the pinned OTP code-path owner about resources without starting an app."""
import json,os,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
os.umask(0o077);ev=Path(__file__).resolve().parent
restored=json.loads((ev/'inputs/server-runtime-restoration04.json').read_text());assert restored['passed']
stage=restored['stage'];image='sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55'
expression='''
P=code:priv_dir(quod),true=is_list(P),
true=filelib:is_regular(filename:join([P,"ontologies","quod_controllers.pl"])),
true=filelib:is_regular(filename:join([P,"native","quod_physics.so"])),
F=code:which(quod_lifecycle_single_path_tests),true=is_list(F),
C=code:which(quod_client_view),true=is_list(C),
io:format("M4_SERVER_RESOURCE_OWNER ~p~n",[{P,F,C}]),halt().
'''
command=['docker','run','--rm','--network','none','-v',stage+':/work:ro','-w','/work',
 '--entrypoint','/bin/sh',image,'-c',
 'exec erl -noshell -pa /work/_build/prod/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh',expression]
result=subprocess.run(command,capture_output=True,timeout=20)
record={'command':command,'true_child_exit':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode(),
 'network':'none','stage_mount':'readonly','application_started':False,'domain_write':False,
 'passed':result.returncode==0 and b'M4_SERVER_RESOURCE_OWNER ' in result.stdout}
(ev/'inputs/server-owner-layout-probe01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record));raise SystemExit(0 if record['passed'] else 1)

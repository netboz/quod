import pathlib,subprocess,sys,time,json
root=pathlib.Path('/home/yan/src/quod')
p=pathlib.Path(__file__).resolve().parent
label=sys.argv[1]
with (p/('stopped-ledger-profile'+label+'.log')).open('x') as log:
 start=time.monotonic()
 result=subprocess.run(['erlc','-o',str(p),str(p/'stopped-ledger-profile.erl')],cwd=root,stdout=log,stderr=subprocess.STDOUT)
 if result.returncode==0:
  paths=[str(path) for path in (root/'_build/test/lib').glob('*/ebin')]+[str(root/'_build/test/lib/quod/test'),str(p)]
  result=subprocess.run(['erl','-pa',*paths,'-noshell','-eval',"try 'stopped-ledger-profile':run() of _ -> halt(0) catch C:R:S -> io:format(\"~p:~p~n~p~n\",[C,R,S]), halt(1) end."],cwd=root,stdout=log,stderr=subprocess.STDOUT)
 data=dict(exit=result.returncode,seconds=time.monotonic()-start)
 (p/('stopped-ledger-profile'+label+'.json')).write_text(json.dumps(data)+'\n')
 print(data)
raise SystemExit(result.returncode)

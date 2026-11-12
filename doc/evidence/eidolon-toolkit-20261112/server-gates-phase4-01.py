import pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[3]
runner=str(pathlib.Path(__file__).parent.joinpath("run-gate.py"))
steps=[("clean-default",["rebar3","clean","--all"]),("clean-test",["rebar3","as","test","clean","--all"]),("eunit",["rebar3","as","test","eunit"]),("ct",["rebar3","as","test","ct"]),("xref",["rebar3","xref"]),("dialyzer",["rebar3","dialyzer"])]
failures=[]
for name,command in steps:
 result=subprocess.run([sys.executable,runner,"phase4-server-01-"+name,*command],cwd=root,stdout=subprocess.DEVNULL)
 if result.returncode: failures.append((name,result.returncode))
print("PHASE4_SERVER_01_RESULT "+repr(failures),flush=True)
sys.exit(1 if failures else 0)

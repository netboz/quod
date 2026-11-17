import pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[3]
runner=str(pathlib.Path(__file__).parents[1].joinpath("ontology-references-phase2-20261110","run-gate.py"))
steps=[("clean-default",["rebar3","clean","--all"]),("clean-test",["rebar3","as","test","clean","--all"]),("eunit",["rebar3","as","test","eunit"]),("ct",["rebar3","as","test","ct"]),("xref",["rebar3","xref"]),("dialyzer",["rebar3","dialyzer"])]
failures=[]
for name,command in steps:
 result=subprocess.run([sys.executable,runner,"commit284-server-01-"+name,*command],cwd=root)
 if result.returncode: failures.append((name,result.returncode))
print("COMMIT284_SERVER_01_RESULT "+repr(failures),flush=True)
sys.exit(1 if failures else 0)

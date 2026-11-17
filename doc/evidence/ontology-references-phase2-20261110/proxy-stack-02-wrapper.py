import faulthandler,runpy,sys,pathlib
trace=open('/tmp/pearl-phase2-proxy-stack-02.log','x')
faulthandler.dump_traceback_later(45,repeat=False,file=trace)
script=sys.argv.pop(1)
sys.argv[0]=script
sys.path.insert(0,str(pathlib.Path(script).parent))
try: runpy.run_path(script,run_name='__main__')
finally: faulthandler.cancel_dump_traceback_later();trace.close()

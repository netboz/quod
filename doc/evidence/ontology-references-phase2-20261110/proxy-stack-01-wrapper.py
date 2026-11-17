import faulthandler,runpy,sys
trace=open('/tmp/pearl-phase2-proxy-stack-01.log','x')
faulthandler.dump_traceback_later(45,repeat=False,file=trace)
script=sys.argv.pop(1)
sys.argv[0]=script
try: runpy.run_path(script,run_name='__main__')
finally: faulthandler.cancel_dump_traceback_later();trace.close()

import sys,subprocess,resource,json,time,pathlib
start=time.monotonic()
r=subprocess.run(['escript','doc/evidence/voxel-world-20261016/generation-measurements.escript',sys.argv[1]])
u=resource.getrusage(resource.RUSAGE_CHILDREN)
pathlib.Path(sys.argv[1]).with_name('process.json').write_text(json.dumps({'exit':r.returncode,'wall_seconds':time.monotonic()-start,'user_seconds':u.ru_utime,'system_seconds':u.ru_stime,'max_rss_kib':u.ru_maxrss,'meaning':'Peak resident set of the complete benchmark VM; includes baseline, measurement overhead, and GC. Not incremental native memory.'},indent=2)+'\n')
sys.exit(r.returncode)

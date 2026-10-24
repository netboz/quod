import pathlib,subprocess,sys,re
count=0
for p in sorted(pathlib.Path('client/test').glob('*.test.js')):
 r=subprocess.run(['node',str(p)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 print(r.stdout,flush=True)
 m=re.search(r'(?:ℹ |# )pass (\d+)',r.stdout)
 if r.returncode or not m or re.search(r'(?:ℹ |# )(?:fail|cancelled) [1-9]',r.stdout):sys.exit(r.returncode or 1)
 count+=int(m.group(1))
print(f'CLIENT_TOTAL passed={count} failed=0',flush=True)

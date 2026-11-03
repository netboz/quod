"""Read-only focus listener with one bounded successor-recipient classification."""
import argparse,datetime,hashlib,json,math,os,re,selectors,socket,stat,struct,subprocess,sys,time
from pathlib import Path

class FocusEvents:
    """Keep only boolean focus evidence; a snapshot never overwrites event order."""
    def __init__(self,address,deadline,emit,on_loss=None):
        if not re.fullmatch(r'0x[0-9a-fA-F]+',address):raise ValueError('owned address syntax')
        self.address=int(address,16);self.deadline=deadline;self.emit=emit
        self.buffer=b'';self.last=None;self.closed=False;self.events=0;self.on_loss=on_loss
    def row(self,kind,now,utc,**values):self.emit(dict(kind=kind,monotonic=now,utc=utc,**values))
    def expire(self,now,utc):
        if not self.closed and now>=self.deadline:
            self.row('absolute_deadline',now,utc);self.closed=True
        return self.closed
    def snapshot(self,owned,now,utc):
        if not self.expire(now,utc):self.row('snapshot',now,utc,owned=bool(owned),ordered_event_barrier=False)
    def error(self,name,now,utc):
        if not self.closed:self.row('listener_error',now,utc,error=name);self.closed=True
    def feed(self,data,now,utc):
        if self.expire(now,utc):return
        self.buffer+=data
        while b'\n' in self.buffer:
            line,self.buffer=self.buffer.split(b'\n',1)
            event,separator,payload=line.partition(b'>>')
            if event!=b'activewindowv2':continue
            if not separator or not re.fullmatch(rb'[0-9a-fA-F]*',payload):
                self.error('malformed_focus_address',now,utc);return
            owned=bool(payload) and int(payload,16)==self.address;self.events+=1
            if self.last is None or owned!=self.last:
                previous=self.last;self.last=owned;self.row('transition',now,utc,owned=owned)
                if previous is True and not owned and self.on_loss is not None:self.on_loss(payload,now,utc)
        # Owner limits event data to1024 bytes. This is a framing error bound,
        # not a controller population/resource policy or a retry path.
        if len(self.buffer)>65536:self.error('unterminated_protocol_line',now,utc)
    def eof(self,now,utc):
        if not self.closed:
            self.row('remote_eof',now,utc,incomplete_line=bool(self.buffer));self.closed=True
    def finish(self,now,utc):
        if not self.expire(now,utc):
            self.row('local_subscription_close',now,utc,incomplete_line=bool(self.buffer));self.closed=True

class RemainingBudget:
    """Every blocking bootstrap operation shares the caller's absolute budget."""
    def __init__(self,deadline,clock=time.monotonic):self.deadline=deadline;self.clock=clock
    def timeout(self):
        if not math.isfinite(self.deadline):raise ValueError('absolute deadline')
        left=self.deadline-self.clock()
        if left<=0:raise TimeoutError('original observation deadline')
        return min(5,left)
    def call(self,operation,*args,**kwargs):return operation(*args,timeout=self.timeout(),**kwargs)
    def connect(self,connection,path):
        connection.settimeout(self.timeout())
        return connection.connect(path)

class RecipientLookupError(Exception):pass

class SuccessorRecipient:
    """First event-anchored loss only; immutable caller roles are not an inventory."""
    def __init__(self,bindings,budget,lookup,incarnation,emit,clock,utc):
        self.bindings={};self.budget=budget;self.lookup=lookup;self.incarnation=incarnation
        self.emit=emit;self.clock=clock;self.utc=utc;self.done=False;self.lookups=0
        for binding in bindings:
            assert set(binding)=={'role','address','pid','starttime','executable','device','inode'}
            assert binding['role'] in {'task','coordinator','runtime'}
            assert re.fullmatch(r'0x[0-9a-fA-F]+',binding['address'])
            assert all(type(binding[k]) is int and binding[k]>0 for k in ['pid','device','inode'])
            assert isinstance(binding['starttime'],str) and binding['starttime'].isdigit() and int(binding['starttime'])>0
            assert isinstance(binding['executable'],str) and Path(binding['executable']).is_absolute()
            address=int(binding['address'],16);assert address not in self.bindings
            self.bindings[address]=dict(binding)
    def __call__(self,payload,received,received_utc):
        if self.done:return
        self.done=True
        row={'kind':'successor_recipient','event_receive_monotonic':received,'event_receive_utc':received_utc,
             'role':'unknown','validity':'unbound','lookup_attempted':False,'recipient_not_initiator':True}
        failure=None
        try:
            self.budget.timeout()
            if not payload:row.update(role='none',validity='empty_notification')
            elif int(payload,16) in self.bindings:
                binding=self.bindings[int(payload,16)];timeout=self.budget.timeout()
                row.update(lookup_attempted=True,lookup_start_monotonic=self.clock(),lookup_start_utc=self.utc())
                self.lookups+=1
                try:clients=self.lookup(timeout=timeout)
                finally:row.update(lookup_end_monotonic=self.clock(),lookup_end_utc=self.utc())
                self.budget.timeout();assert isinstance(clients,list) and all(isinstance(w,dict) for w in clients)
                matches=[w for w in clients if isinstance(w.get('address'),str) and
                         re.fullmatch(r'0x[0-9a-fA-F]+',w['address']) and int(w['address'],16)==int(payload,16)]
                if len(matches)!=1 or type(matches[0].get('pid')) is not int or matches[0]['pid']!=binding['pid'] or matches[0].get('mapped') is not True:
                    row['validity']='window_owner_mismatch'
                else:
                    try:current=self.incarnation(binding)
                    except ProcessLookupError:row['validity']='incarnation_unavailable'
                    else:
                        self.budget.timeout();row['incarnation_checked_monotonic']=self.clock()
                        if current==(binding['starttime'],binding['device'],binding['inode']):
                            row.update(role=binding['role'],validity='confirmed_at_lookup')
                        else:row['validity']='incarnation_mismatch'
        except TimeoutError:row['validity']='expired';failure=TimeoutError
        except Exception:row['validity']='lookup_error';failure=RecipientLookupError
        row.update(monotonic=self.clock(),utc=self.utc());self.emit(row)
        if failure is not None:raise failure('successor classification failed') from None

def process_incarnation(pid,executable,budget):
    budget.timeout();directory=Path('/proc')/str(pid)
    try:
        data=(directory/'stat').read_text();started=data[data.rfind(')')+2:].split()[19]
        actual=directory/'exe';expected=Path(executable);s=actual.stat();e=expected.stat()
        assert actual.resolve()==expected.resolve() and (s.st_dev,s.st_ino)==(e.st_dev,e.st_ino)
    except FileNotFoundError:raise ProcessLookupError('process incarnation unavailable') from None
    budget.timeout();return started,s.st_dev,s.st_ino

def run():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['pid','address','executable','instance-signature','deadline-monotonic','private-dir','recipient-bindings']:p.add_argument('--'+name,required=True)
    a=p.parse_args();os.umask(0o077);pid=int(a.pid);deadline=float(a.deadline_monotonic)
    private=Path(a.private_dir);task=Path('/data/quod-m4-vr-ca84d4f8-20261029/private')
    assert private.resolve().is_relative_to(task.resolve());private.mkdir(mode=0o700,parents=True,exist_ok=False)
    rows=[];record={'armed':False,'runtime_started':False,'focus_changed':False,'subscription_count':0,'errors':[]}
    stream=(private/'filtered-events.jsonl').open('x',encoding='utf-8')
    def emit(row):
        rows.append(row);stream.write(json.dumps(row)+'\n');stream.flush()
        print(json.dumps(row),flush=True)
    def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
    observer=FocusEvents(a.address,deadline,emit);budget=RemainingBudget(deadline);connection=None;selector=None;recipient=None
    def query(what,*,timeout):return json.loads(subprocess.check_output(['hyprctl','-j',what],stderr=subprocess.PIPE,timeout=timeout))
    def incarnation():return process_incarnation(pid,a.executable,budget)
    try:
        original=incarnation()
        roles=Path(a.recipient_bindings);assert roles.resolve().is_relative_to(task.resolve()) and not roles.is_symlink()
        assert roles.is_file() and roles.stat().st_mode&0o7777==0o600 and roles.parent.stat().st_mode&0o7777==0o700
        budget.timeout();bindings=json.loads(roles.read_text());budget.timeout();assert isinstance(bindings,list)
        bindings=[{'role':'task','address':a.address,'pid':pid,'starttime':original[0],
                   'executable':a.executable,'device':original[1],'inode':original[2]},*bindings]
        recipient=SuccessorRecipient(bindings,budget,lambda **kwargs:query('clients',**kwargs),
             lambda binding:process_incarnation(binding['pid'],binding['executable'],budget),emit,time.monotonic,utc)
        observer.on_loss=recipient
        # Conservative deadline is earlier than the existing driver's manual
        # timer, which begins only after application readiness. Never reset it.
        elapsed=float(Path('/proc/uptime').read_text().split()[0])-int(original[0])/os.sysconf('SC_CLK_TCK')
        assert time.monotonic()<deadline<=time.monotonic()+1800-math.ceil(elapsed)-1
        assert os.environ['HYPRLAND_INSTANCE_SIGNATURE']==a.instance_signature
        version=budget.call(query,'version');assert version['commit']=='efb50993780079460b0cbed1363e2166a2de1d9f' and not version['dirty']
        owned=[w for w in budget.call(query,'clients') if w.get('pid')==pid and w.get('mapped')]
        assert len(owned)==1 and owned[0]['address'].lower()==a.address.lower()
        path=Path(os.environ['XDG_RUNTIME_DIR'])/'hypr'/a.instance_signature/'.socket2.sock'
        assert stat.S_ISSOCK(path.stat().st_mode) and path.stat().st_uid==os.getuid()
        connection=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);budget.connect(connection,str(path));connection.setblocking(False)
        peer_pid,peer_uid,_=struct.unpack('3i',connection.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12));assert peer_uid==os.getuid()
        record.update(subscription_count=1,peer_pid=peer_pid,instance_sha256=hashlib.sha256(a.instance_signature.encode()).hexdigest())
        # Subscribe BEFORE querying. Socket2 has no acknowledgement/barrier or
        # sequence numbers. Preserve queued events; the snapshot is separate
        # evidence and never replaces/reorders the event stream's boolean state.
        active=budget.call(query,'activewindow');assert incarnation()==original
        initial=active.get('pid')==pid and active.get('address','').lower()==a.address.lower()
        observer.snapshot(initial,time.monotonic(),utc())
        if observer.closed:raise TimeoutError('original observation deadline')
        record['armed']=True
        print('M4_FOCUS_EVENT_OBSERVER_READY '+json.dumps({'owned_snapshot':initial,'protocol_acknowledgement':False,'deadline_monotonic':deadline}),flush=True)
        selector=selectors.DefaultSelector();selector.register(connection,selectors.EVENT_READ,'events');selector.register(sys.stdin,selectors.EVENT_READ,'control')
        while not observer.closed:
            now=time.monotonic()
            if observer.expire(now,utc()):break
            available=selector.select(deadline-now)
            for key,_ in sorted(available,key=lambda r:r[0].data!='events'):
                now=time.monotonic()
                if observer.expire(now,utc()):break
                if key.data=='events':
                    data=connection.recv(65536)
                    if not data:observer.eof(now,utc());break
                    assert incarnation()==original
                    observer.feed(data,now,utc())
                else:
                    command=sys.stdin.readline().strip()
                    if command=='finish':observer.finish(now,utc())
                    else:observer.error('control_eof_or_cancel',now,utc())
    except Exception as error:
        record['errors'].append(type(error).__name__);now=time.monotonic()
        if not observer.expire(now,utc()):observer.error(type(error).__name__,now,utc())
    finally:
        if selector is not None:selector.close()
        if connection is not None:connection.close()
        stream.close();record.update(rows=len(rows),event_messages=observer.events,unparsed_fragment=bool(observer.buffer),
          local_connection_closed=connection is not None,remote_eof_observed=any(r['kind']=='remote_eof' for r in rows),
          snapshot_is_not_ordered_event_barrier=True,continuous_native_or_pixel_claim=False,
          successor_classifications=int(recipient.done) if recipient is not None else 0,
          successor_lookups=recipient.lookups if recipient is not None else 0,successor_is_not_focus_initiator=True)
        (private/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
    return 0 if record['armed'] and not record['errors'] and any(r['kind']=='local_subscription_close' and not r['incomplete_line'] for r in rows) else 1

if __name__=='__main__':raise SystemExit(run())

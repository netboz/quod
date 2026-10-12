from pathlib import Path
import json,sys,owner
p=Path(__file__).resolve().parent
ns=sys.argv[1];world=sys.argv[2];body=int(sys.argv[3]);sequence=int(sys.argv[4]);label=sys.argv[5]
q='''Ns= <<"NAMESPACE">>,W=WORLD,B=BODY,Seq=SEQ,true=quod_reg:subscribe({runtime,Ns}),D=quod_time:mono_ms()+30000,
Wait=fun Again()->case quod_prolog:prove_ro(Ns,{physics_hinged,W,B,Seq,{finished,{'R'},{'O'}}}) of
 {ok,[Row],_}->Row;
 _->receive {projection_advanced,_,_}->Again() after max(0,D-quod_time:mono_ms())->error({finish_deadline,W,B,Seq}) end end end,
Row=Wait(),Fmt=fun(T)->iolist_to_binary(io_lib:format("~0p",[T])) end,
{ok,[#{'Cs':=Cs}],_}=quod_prolog:prove_ro(Ns,{findall,{'C'},{physics_checkpoint,W,{'C'}},{'Cs'}}),
{ok,[#{'Rs':=Rs}],_}=quod_prolog:prove_ro(Ns,{findall,{hinged_result,{'Result'},{'Request'}},{hinged_result,{'Result'},{'Request'}},{'Rs'}}),
{Runtime,_}=quod_runtime:agents(Ns),World={world_ref,Ns,quod_simplex:genesis_hash(Ns),W},#{World:=#{pid:=Pid,spec:=Spec,stopping:=false}}=gen_server:call(Runtime,physics_worlds),
Status=gen_server:call(Pid,status),{ok,Frame,Counters}=quod_physics:snapshot(Pid,#{fence=>quod_physics:fence(Spec),structure=>maps:get(structure,Spec),tick=> -1}),
#{height=>quod_prolog:applied(Ns),state=>Fmt(Row),checkpoints=>Fmt(Cs),consequences=>Fmt(Rs),spec=>Fmt(Spec),status=>Fmt(Status),frame=>Fmt(Frame),counters=>Counters,finished=>true}
'''.replace('NAMESPACE',ns).replace('WORLD',world).replace('BODY',str(body)).replace('SEQ',str(sequence))
r=owner.read(label,q);print(json.dumps({k:r[k] for k in ['height','state','checkpoints','consequences','counters']}))

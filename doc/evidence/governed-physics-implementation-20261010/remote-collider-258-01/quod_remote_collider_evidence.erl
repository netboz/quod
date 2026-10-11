-module(quod_remote_collider_evidence).
-export([node/0, found/3, request/3, submit/2, world/1, unchanged/2,
         observed_submit/7, resolve/2, found_world/2, found_source/4,
         preparation/3, activation/6, source_operation/5, installed/2,
         receipt/2]).

%% Temporary evidence driver. All domain changes enter existing Prolog actions
%% and signed ingress. This module is neither a predicate nor a runtime owner.
node() ->
    {ok, Ref} = quod_node_actor:reference(),
    #{reference => encoded(Ref), node_key => binary:encode_hex(
        element(2, application:get_env(quod, node_pubkey)))}.

found_world(Ns, EncodedEditor) ->
    {ok, Host} = quod_node_actor:reference(), Editor = decoded(EncodedEditor),
    Terms = [{can_invoke,{'_'},Host,{'_'},Ns},
        {can_invoke,{'_'},Editor,{'_'},Ns},
        {can_prepare_agent_key,Host,physics_authority,none,0,Host},
        {can_assign_agent_host,Host,physics_authority,none,0,Host,{'_'}}],
    found(Ns,["agent_instance.pl","space.pl","quod_physics.pl"],encoded(Terms)).

found_source(Ns, WorldNs, WorldAnchorHex, EncodedHost) ->
    Anchor = binary:decode_hex(WorldAnchorHex), Host = decoded(EncodedHost),
    {ok, Editor} = quod_node_actor:reference(),
    Destination = {entity_ref,WorldNs,Anchor,room},
    World = {world_ref,WorldNs,Anchor,room},
    Authority = {agent_instance_ref,WorldNs,Anchor,physics_authority},
    Terms = [{can_invoke,{'_'},Editor,{'_'},Ns},{can_invoke,{'_'},Host,{'_'},Ns},
        {instance_of,artifact,obstacle},
        {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}},
        {physics_definition_allowance,obstacle,1000000},
        {can_edit_physics_definition,obstacle,Editor},
        {can_delegate_physics_definition,obstacle,Editor,World,Authority},
        {can_enter_space,obstacle,Editor,Destination,physical},
        {can_leave_space,obstacle,Editor,Destination,physical}],
    found(Ns,["space.pl","quod_physics.pl"],encoded(Terms)).

preparation(Ns, AnchorHex, Operation) ->
    {ok, Host} = quod_node_actor:reference(),
    Ref = {agent_instance_ref,Ns,binary:decode_hex(AnchorHex),physics_authority},
    request(read,encoded({'::',Ns,{prepare_agent_key_custody,Ref,none,0,Host,{0}}}),Operation).

activation(Ns, AnchorHex, Source, SourceAnchorHex, EncodedEditor, Input) ->
    #{key_values := KeyValues, operation := Operation} = Input,
    [{<<"V0">>,Key}] = decoded(KeyValues),
    {ok, Host} = quod_node_actor:reference(), Editor = decoded(EncodedEditor),
    Anchor = binary:decode_hex(AnchorHex), SourceAnchor = binary:decode_hex(SourceAnchorHex),
    Authority = {agent_instance_ref,Ns,Anchor,physics_authority},
    Subject = {entity_ref,Source,SourceAnchor,obstacle},
    Rows = [{instance_of,physical_space,room},
        {physics_space,room,enabled,physics_authority},
        {physics_run,room,0,none},{physics_structure,room,1},{physics_next_body,room,2},
        {physics_allowances,room,{limits,16,16,128,1000000,{geometry,32,128,128}},16667,0,10000},
        {physics_body_definition,room,1,1,fixed,{vector,0,-250,0},{owned,{box,8000,250,8000},1}},
        {can_request_agent_signature,Host,physics_authority,{'_'}},
        {can_invoke,{physics_store_request,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Authority,{'_'},Ns},
        {can_invoke,{physics_activate,{'_'},{'_'},{'_'}},Authority,{'_'},Ns},
        {subscribes,Source,SourceAnchor},
        {can_admit_space_member,room,Editor,Subject,physical},
        {can_remove_space_member,room,Editor,Subject,physical},
        {can_refresh_physics_definition,room,Editor,Subject},
        {physics_admission,room,Subject,fixed,{vector,4000,1000,0}},
        {':-',{space_physical_change,{'W'},{'S'},{'Change'}},
              {physics_space_change,{'W'},{'S'},{'Change'}}}],
    Goal = {transaction,conjunction([
        {current_ontology_identity,Ns,Anchor},
        {'\\+',{physics_space,room,{0},{1}}},
        {goal,{agent_hosted,physics_authority,Host,1,Key}},
        {physics_checked_body,1,fixed,{vector,0,-250,0},{box,8000,250,8000},1,1000000}]
        ++ [{assertz,R} || R <- Rows])},
    request(execute,encoded({'::',Ns,Goal}),Operation).

source_operation(Ns, WorldNs, AnchorHex, Kind, Operation) ->
    Destination = {entity_ref,WorldNs,binary:decode_hex(AnchorHex),room},
    Goal = case Kind of
        admission -> {space_place,obstacle,0,Destination};
        edit -> {physics_edit_definition,obstacle,1,{geometry,{ball,600},1}};
        unrelated -> {assertz,{unrelated_note,geometry_unchanged}};
        withdrawal -> {space_withdraw,obstacle,1,Destination}
    end,
    request(execute,encoded({'::',Ns,Goal}),Operation).

found(Ns, Files, EncodedTerms) ->
    {ok, not_hosted} = quod_ontology:local_state(Ns),
    Terms = decoded(EncodedTerms),
    Options = [{source_file, list_to_binary(filename:join(
        [code:priv_dir(quod), "ontologies", File]))} || File <- Files] ++
        [{terms, Terms}, {external_predicate_modules, [quod_agent_predicates]}],
    true = quod_reg:subscribe({runtime, Ns}),
    try
        Outcome = quod_prolog:execute(<<"quod:root">>,
            {create_ontology, Ns, Options, {'Anchor'}}),
        {ok, [#{'Anchor' := Anchor}], _} = Outcome,
        await_ready(Ns, quod_time:mono_ms() + 60000),
        Anchor = quod_simplex:genesis_hash(Ns),
        #{namespace => Ns, anchor => binary:encode_hex(Anchor),
          committee => [binary:encode_hex(K) || K <- quod_simplex:committee(Ns)],
          outcome => text(Outcome)}
    after quod_reg:unsubscribe({runtime, Ns}) end.

request(Mode, EncodedGoal, Operation) ->
    {Goal,_,_} = erlog_int:term_instance(decoded(EncodedGoal),0),
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(
        Mode, Goal, binary:decode_hex(Operation), quod_time:now_ms() + 30000),
    #{bytes => base64:encode(Bytes), signature => base64:encode(Signature)}.

submit(Bytes, Signature) ->
    result(quod_client_goal_ingress:submit(base64:decode(Bytes), base64:decode(Signature))).

resolve(Bytes, Signature) ->
    result(quod_client_goal_ingress:resolve_operation(base64:decode(Bytes), base64:decode(Signature))).

receipt(Bytes, Signature) ->
    {ok, #{operation_ref := Op = {operation,Ns,_,_,_}}} =
        quod_client_goal:verify(base64:decode(Bytes),base64:decode(Signature)),
    true = quod_reg:subscribe({runtime,Ns}),
    try await_receipt(Ns,Op,quod_time:mono_ms()+5000)
    after quod_reg:unsubscribe({runtime,Ns}) end.

await_receipt(Ns, Op, Deadline) ->
    Remaining = Deadline-quod_time:mono_ms(), true = Remaining > 0,
    {ok, #{applied_floor := Floor,outcome := Outcome}} =
        quod_prolog:outcome_snapshot(Ns,Op,Remaining),
    case Outcome of
        #{operation_state := terminal,receipt_height := Height} when Height =< Floor ->
            #{receipt_height => Height, applied_floor => Floor, terminal => true};
        _ -> receive {projection_advanced,_,_} -> await_receipt(Ns,Op,Deadline)
             after Remaining -> error(receipt_not_published) end
    end.

result(Result) ->
    Read = case Result of
        {ok, _, {normalized, {read, _, {answers, 1, [Answer]}}}} ->
            {ok, Values} = quod_durable_term:decode_result(Answer),
            #{read_values => text(Values), read_encoded => encoded(Values)};
        _ -> #{}
    end,
    Read#{term => text(Result), encoded => encoded(Result),
      committed => case Result of
        {ok, _, {normalized, {committed, _, _}}} -> true;
        _ -> false
      end}.

world(Ns) ->
    Rows = worlds(Ns),
    #{namespace => Ns, anchor => binary:encode_hex(quod_simplex:genesis_hash(Ns)),
      height => quod_prolog:applied(Ns), runtime => runtime_barrier(Ns),
      worlds => [describe(W, Row) || {W, #{stopping := false} = Row} <- maps:to_list(Rows)]}.

installed(Ns, Structure) ->
    true = quod_reg:subscribe({physics,Ns}),
    try await_structure(Ns,Structure,quod_time:mono_ms()+15000), world(Ns)
    after quod_reg:unsubscribe({physics,Ns}) end.

describe(W, #{pid := Pid, spec := Spec}) ->
    Status = gen_server:call(Pid,status),
    #{world => text(W), pid => text(Pid), structure => maps:get(structure, Spec),
      fence => text(quod_physics:fence(Spec)), bodies => text(maps:get(bodies, Spec)),
      body_revisions => [#{body => Id,revision => Revision} ||
          {Id,Revision,_,_,_,_} <- maps:get(bodies,Spec)],
      counters => maps:with([installs,steps,queries,tick,navigation_ready],Status),
      status => text(Status)}.

unchanged(Ns, EncodedReader) ->
    {Reader, _Generation} = decoded(EncodedReader),
    true = is_process_alive(Reader),
    Before = world(Ns),
    {ok, _, Counts, NodeCounts} = measured(Ns, [Reader], fun() ->
        [ok = quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns),
             physics_worlds, all, quod_time:mono_ms() + 10000)
         || _ <- lists:seq(1, 20)],
        world(Ns)
    end),
    true = is_process_alive(Reader),
    #{before => Before, after_checks => world(Ns), checks => 20,
      work => Counts, node_work => NodeCounts}.

observed_submit(Ns, Source, SourceAnchorHex, PriorReader, Structure, Bytes, Signature) ->
    SourceAnchor = binary:decode_hex(SourceAnchorHex),
    Readers = case PriorReader of none -> []; _ -> [element(1,decoded(PriorReader))] end,
    true = quod_reg:subscribe({physics, Ns}),
    Runtime = quod_reg:where({quod_runtime,Ns}), Owner = self(), Token = make_ref(),
    Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,Anchor0},
                           {advanced,From,Height,Projection,Freshness,Heads,_}}},_)
                    when Source0 =:= Source, Anchor0 =:= SourceAnchor ->
                      Owner ! {source_advanced,Token,Height,From,Projection,Freshness,Heads}, State;
                 (State,_,_) -> State end,
    ok = sys:install(Runtime,{Observe,none}),
    try
        Before = world(Ns),
        {ok, {Outcome,Notice}, Counts, NodeCounts} = measured(Ns, Readers, fun() ->
            Result = submit(Bytes, Signature),
            SourceNotice = case maps:get(committed, Result) of
                true ->
                    Min = source_height(decoded(maps:get(encoded,Result)),Source,SourceAnchor),
                    receive {source_advanced,Token,H,From,Projection,Freshness,Heads} when H >= Min ->
                        _ = runtime_barrier(Ns),
                        await_structure(Ns, Structure, quod_time:mono_ms() + 15000),
                        #{minimum_height => Min,height => H,from => From,
                          projection => binary:encode_hex(Projection),changed_heads => text(Heads),
                          reader => encoded(maps:get(reader,Freshness))}
                    after 15000 -> error({source_advance_missing,Min}) end;
                false -> #{}
            end,
            {Result,SourceNotice}
        end),
        #{before => Before, after_change => world(Ns), outcome => Outcome,
          source_notice => Notice,work => Counts,node_work => NodeCounts}
    after sys:remove(Runtime,Observe), quod_reg:unsubscribe({physics, Ns}) end.

source_height({ok,_,{normalized,{committed,_,{group_outcome,_,_,Slots}}}},Ns,Anchor) ->
    [{_,Height,_}] = [Row || {{N,A},_,_} = Row <- Slots,N =:= Ns,A =:= Anchor], Height;
source_height({ok,_,{normalized,{committed,_,{transaction,Ns,Anchor,_} = Ref}}},Ns,Anchor) ->
    {ok,#{status := committed,height := Height}} = quod_prolog:outcome(Ref), Height.

runtime_barrier(Ns) -> gen_server:call(quod_reg:via({quod_runtime,Ns}),get_stats,5000).

measured(Ns, Readers, Fun) ->
    Collector = spawn_link(fun() -> collect(#{}) end),
    Trace = trace:session_create(quod_remote_collider_evidence, Collector, []),
    NodeCollector = spawn_link(fun() -> collect(#{}) end),
    NodeTrace = trace:session_create(quod_remote_collider_node_evidence,NodeCollector,[]),
    Owners = lists:usort([quod_reg:where({quod_runtime,Ns}) | Readers] ++
        [Pid || #{pid := Pid,stopping := false} <- maps:values(worlds(Ns))]),
    Watched = [{quod_foreign_projection,start_monitor,4},
        {quod_committed_projection,apply_entry,3},
        {quod_physics_native,install,2},{quod_physics_native,install_hinges,2},
        {quod_physics_native,new_world,3},{quod_physics_native,step,2},
        {quod_ledger_store,fold,5},{quod_ledger_store,open,3},
        {file,write,2},{file,pwrite,3},{file,sync,1},{file,datasync,1}],
    try
        [begin
            {module, M} = code:ensure_loaded(M),
            Matched = trace:function(Trace,MFA,[{'_',[],[{message,{caller}}]}],[local]),
            Matched = trace:function(NodeTrace,MFA,[{'_',[],[{message,{caller}}]}],[local]),
            true = Matched > 0
         end || MFA = {M,_,_} <- Watched],
        [trace:process(Trace,Pid,true,[call,arity,set_on_spawn]) || Pid <- Owners],
        trace:process(NodeTrace,all,true,[call,arity]),
        Value = Fun(),
        Counts = finish_trace(Trace,Collector),
        NodeCounts = finish_trace(NodeTrace,NodeCollector),
        {ok, Value, Counts, NodeCounts}
    after
        trace:session_destroy(Trace), trace:session_destroy(NodeTrace),
        unlink(Collector),exit(Collector,kill),unlink(NodeCollector),exit(NodeCollector,kill)
    end.

finish_trace(Trace,Collector) ->
    trace:process(Trace,all,false,[call,set_on_spawn]),
    Delivered = trace:delivered(Trace,all),
    receive {trace_delivered,all,Delivered} -> ok after 5000 -> error(trace_delivery_timeout) end,
    Ref = make_ref(), Collector ! {finish,self(),Ref},
    receive {counts,Ref,C} -> C after 5000 -> error(trace_collector_timeout) end.

%% Arity-only tracing never captures key material, terms or file contents.
collect(Counts) ->
    receive
        {trace,Pid,call,MFA,Caller} ->
            Key = text({Pid,MFA,Caller}),
            collect(maps:update_with(Key, fun(N) -> N+1 end, 1, Counts));
        {finish,Owner,Ref} -> Owner ! {counts,Ref,Counts}
    end.

worlds(Ns) -> gen_server:call(quod_reg:via({quod_runtime,Ns}), physics_worlds).

await_ready(Ns, Deadline) ->
    case quod_ontology:local_state(Ns) of
        {ok, ready} -> ok;
        _ -> receive {projection_advanced,_,_} -> await_ready(Ns,Deadline);
                     _ -> await_ready(Ns,Deadline)
             after max(0,Deadline-quod_time:mono_ms()) -> error({not_ready,Ns}) end
    end.

await_structure(Ns, Structure, Deadline) ->
    Ready = [Pid || #{pid := Pid,spec := #{structure := S},stopping := false}
                       <- maps:values(worlds(Ns)), S =:= Structure,
                   maps:get(navigation_ready,gen_server:call(Pid,status),false)],
    case Ready of
        [_] -> ok;
        _ -> receive {physics_status,_,_,_,_,_} -> await_structure(Ns,Structure,Deadline)
             after max(0,Deadline-quod_time:mono_ms()) -> error({not_installed,Ns,Structure}) end
    end.

encoded(Term) -> base64:encode(term_to_binary(Term)).
decoded(Bytes) -> binary_to_term(base64:decode(Bytes), [safe]).
text(Term) -> iolist_to_binary(io_lib:format("~0p",[Term])).
conjunction([]) -> true;
conjunction([Goal|Rest]) -> {',',Goal,conjunction(Rest)}.

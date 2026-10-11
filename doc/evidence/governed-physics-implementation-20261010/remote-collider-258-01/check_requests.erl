-module(check_requests).
-export([run/0]).

run() ->
    {ok,_} = application:ensure_all_started(gproc),
    {ok,_} = application:ensure_all_started(crypto),
    {Pub,_} = Pair = quod_identity:generate(),
    Ref = {agent_instance_ref,<<"request-check-node">>,<<9:256>>,physical_node},
    {ok,Blob} = quod_wire_term:encode_canonical(Ref),
    application:set_env(quod,node_actor_principal,{agent,Blob}),
    application:set_env(quod,node_pubkey,Pub),
    application:set_env(quod,identity_key,quod_identity:key_term(Pair)),
    application:set_env(quod,namespace_desired,
        #{content => #{<<"quod:root">> => #{genesis_hash => <<42:256>>}},brahms => #{}}),
    Ns = <<"acceptance:physics:258:gallery">>, A = binary:encode_hex(<<11:256>>),
    Source = <<"acceptance:physics:258:objects">>, SA = binary:encode_hex(<<12:256>>),
    Editor = base64:encode(term_to_binary(Ref)),
    Values = base64:encode(term_to_binary([{<<"V0">>,<<13:256>>}])),
    Prep = quod_remote_collider_evidence:preparation(Ns,A,operation()),
    Activation = quod_remote_collider_evidence:activation(Ns,A,Source,SA,Editor,
        #{key_values => Values,operation => operation()}),
    Cases = [{preparation,Prep},{activation,Activation}] ++
        [{Kind,quod_remote_collider_evidence:source_operation(Source,Ns,A,Kind,operation())}
         || Kind <- [admission,unrelated,edit,withdrawal]],
    Report = [begin
        Bytes = base64:decode(maps:get(bytes,R)),
        Sig = base64:decode(maps:get(signature,R)),
        {ok,#{request := #{goal_text := Text}}} = quod_client_goal:verify(Bytes,Sig),
        {ok,_} = quod_client_goal_parser:parse(Text,3),
        #{name => Name,wire_bytes => byte_size(Bytes),goal_bytes => byte_size(Text)}
    end || {Name,R} <- Cases],
    io:format("~s~n",[json:encode(#{signed_and_parsed => Report,submitted => false})]),
    halt(0).

operation() -> binary:encode_hex(crypto:strong_rand_bytes(32)).

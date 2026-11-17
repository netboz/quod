#!/usr/bin/env escript
%% Evidence-only verification using the compiled production parser and codecs.
main([ReceiptPath, OutputPath]) ->
    Build = os:getenv("QUOD_RECEIPT_BUILD", "/work"),
    ok = code:add_paths(filelib:wildcard(Build ++ "/_build/test/lib/*/ebin")),
    {ok, _} = application:ensure_all_started(crypto),
    {ok, Raw} = file:read_file(ReceiptPath),
    R = json:decode(Raw),
    {agent_instance_ref, <<"node:", PublicHex/binary>>, _, me} = Node =
        term(maps:get(<<"node">>, R)),
    Public = binary:decode_hex(PublicHex),
    32 = byte_size(Public),
    Accounts = maps:get(<<"accounts">>, R),
    Operations = maps:get(<<"signed_operations">>, R),
    Verified = [begin
        {account, U, A, S0, Storage, Key, Pins} = term(Account),
        U = term(maps:get(<<"owner">>, Op)),
        Signup = maps:get(<<"signup">>, Op),
        {operation, <<"quod:user">>, UserClass, SignupBlob, _} =
            term(maps:get(<<"operation">>, Signup)),
        {ok, #{reference := {agent_instance_ref, <<"quod:user">>, UserClass,
                             {signup, HumanPublic}}}} = quod_agent_ref:decode(SignupBlob),
        32 = byte_size(HumanPublic),
        true = HumanPublic =/= Key,
        Setup = maps:get(<<"setup">>, Op),
        {operation, _, _, SetupBlob, _} = term(maps:get(<<"operation">>, Setup)),
        {ok, #{reference := U}} = quod_agent_ref:decode(SetupBlob),
        {prepared_key, Key, Signature} = term(maps:get(<<"custody">>, Op)),
        {ok, Encoded} = quod_wire_term:encode_canonical([A, none, 0, Node, Key]),
        Message = <<"quod.prepared-agent-custody.v1", 0, Encoded/binary>>,
        true = quod_identity:verify(Signature, Message, Public),
        false = quod_identity:verify(Signature, <<Message/binary, 0>>, Public),
        #{human => ref(U), agent => ref(A), initial_space => ref(S0),
          selected_storage => ref(Storage), human_public_key => binary:encode_hex(HumanPublic),
          personal_agent_public_key => binary:encode_hex(Key),
          shared_user_class_anchor => binary:encode_hex(UserClass),
          setup_operation_has_original_human_identity => true,
          pins => quod_client_goal_parser:value_text(Pins),
          custody_signature => binary:encode_hex(Signature),
          custody_message_sha256 => binary:encode_hex(crypto:hash(sha256, Message)),
          exact_receipt_verified => true, altered_message_refused => true}
    end || {Account, Op} <- lists:zip(Accounts, Operations)],
    Result = #{input => list_to_binary(ReceiptPath),
        input_sha256 => binary:encode_hex(crypto:hash(sha256, Raw)),
        node_identity => ref(Node), executor_public_key => binary:encode_hex(Public),
        key_source => <<"Enrolled node namespace node:<hex public key>; both production custody signatures verified against it">>,
        crypto => <<"Existing quod_wire_term:encode_canonical/1 and quod_identity:verify/3">>,
        verification_is_offline_read_only => true, accounts => Verified},
    ok = file:write_file(OutputPath, json:encode(Result)),
    io:format("Verified ~B account custody receipts against enrolled executor ~s~n",
              [length(Verified), binary:encode_hex(Public)]).

term(Text) ->
    {ok, [Term]} = erlog_io:read_string_terms(binary_to_list(<<Text/binary, ".">>)),
    Term.

ref({Type, Namespace, Anchor, Id}) ->
    #{type => Type, namespace => Namespace, anchor => binary:encode_hex(Anchor),
      local_id => quod_client_goal_parser:value_text(Id)};
ref({ontology_ref, Namespace, Anchor}) ->
    #{type => ontology_ref, namespace => Namespace, anchor => binary:encode_hex(Anchor)}.

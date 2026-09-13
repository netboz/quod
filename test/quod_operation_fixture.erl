-module(quod_operation_fixture).
-include("quod_ledger.hrl").
-export([with/2, view/3, entry/4]).

%% One real signed/certified history constructor for owner-interface controls.
%% These genesis-derived projections are trusted owner inputs, not a witness
%% that the generated claims/applications were consensus-admitted or applied.
%% Callers own their process stubs and decide which production callbacks run.
with(N, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8)),
    Ns = <<"quod:operation-result-source-", Suffix/binary>>,
    {NodeKey, Seed} = quod_identity:generate(),
    Signer = #{pubkey => NodeKey, key => quod_identity:key_term({NodeKey, Seed})},
    {Origin, Genesis, SourceProjection} = operation_genesis(Ns, Signer),
    TargetGenesis = [operation_genesis(
      <<"quod:operation-result-target-", Suffix/binary, "-", (integer_to_binary(I))/binary>>, Signer)
      || I <- lists:seq(1, N)],
    Targets = [Target || {Target, _, _} <- TargetGenesis],
    F0 = quod_ct:operation_plan_fixture(#{target => Origin, participant_target => hd(Targets),
      node_identity => Signer, provenance => case N of 1 -> 1; _ -> 2 end}, Targets),
    Admission = maps:get(admission, F0),
    Claim0 = quod_transaction:remote_claim(Origin, maps:get(manifest, F0),
                                          maps:get(bundles, F0), maps:get(auth, F0), []),
    {ok, Claim} = quod_transaction:sign({Ns, element(2, Origin), Admission},
      Claim0#transaction{author = NodeKey, author_seq = 1, submitted_at = 1}, Signer),
    ClaimEntry = entry(Origin, Signer, 2, Claim),
    {ok, ClaimRef} = quod_dtx:certified_entry_ref(Origin, ClaimEntry, Claim),
    {ok, #{operation_ref := OperationRef, digest := Digest}} = quod_transaction:request_claim(Claim),
    Dir = filename:join("/tmp", "quod-s8-operation-fixture-" ++ binary_to_list(Suffix)),
    ok = file:make_dir(Dir),
    Applications = maps:from_list([begin
        {TargetNs, TargetAnchor} = Target,
        App0 = quod_transaction:attach_evidence(
          quod_transaction:remote_application(quod_transaction:stable_ref(ClaimRef), Claim, Target),
          ClaimRef, Claim),
        {ok, App} = quod_transaction:sign({TargetNs, TargetAnchor, Admission},
          App0#transaction{author = NodeKey, author_seq = 1, submitted_at = 1}, Signer),
        Entry = entry(Target, Signer, 2, App),
        {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, App),
        {ok, Store0} = quod_ledger_store:open(TargetNs, Dir),
        {ok, Store} = quod_ledger_store:append(Store0, [G, Entry]),
        Evidence = #{identity => Target, phase => transaction, slot => 2,
          block_hash => operation_entry_hash(Entry), record_digest => App#transaction.tx_id,
          transaction => App, committee => [NodeKey], committee_id => maps:get(committee_id, Projection)},
        {Target, #{target => Target, target_ref => quod_transaction:stable_ref(Ref),
          certified_target_ref => Ref, application => App, evidence => Evidence,
          store => Store, projection => Projection, entry => Entry}}
    end || {Target, G, Projection} <- TargetGenesis]),
    Pairs = [{maps:get(certified_target_ref, maps:get(T, Applications)),
              maps:get(application, maps:get(T, Applications))} || T <- Targets],
    Refs = [maps:get(target_ref, maps:get(T, Applications)) || T <- Targets],
    {ok, Included} = quod_operation_vector:included(Refs),
    Completion0 = quod_transaction:attach_receipt_evidence(
      quod_transaction:remote_complete(Origin, OperationRef, Digest, Included), Pairs),
    {ok, Completion} = quod_transaction:sign({Ns, element(2, Origin), Admission},
      Completion0#transaction{author = NodeKey, author_seq = 2, submitted_at = 3}, Signer),
    CompletionEntry = entry(Origin, Signer, 3, Completion),
    {ok, Source0} = quod_ledger_store:open(Ns, Dir),
    {ok, SourceStore} = quod_ledger_store:append(Source0, [Genesis, ClaimEntry, CompletionEntry]),
    SavedNodeKey = application:get_env(quod, node_pubkey),
    application:set_env(quod, node_pubkey, NodeKey),
    try
        F = F0#{source_ns => Ns, operation_ref => OperationRef,
          request_digest => Digest, claim => Claim, certified_claim_ref => ClaimRef,
          completion => Completion, source_store => SourceStore,
          source_projection => SourceProjection, source_entry => CompletionEntry,
          targets => Targets, target_refs => Refs, target_data => Applications},
        quod_ct:with_network_identity(maps:get(network, F), fun() ->
            Fun(maps:merge(F, maps:get(hd(Targets), Applications)))
        end)
    after
        ok = quod_ledger_store:close(SourceStore),
        [ok = quod_ledger_store:close(maps:get(store, D)) || D <- maps:values(Applications)],
        ok = file:del_dir_r(Dir),
        case SavedNodeKey of
            {ok, Value} -> application:set_env(quod, node_pubkey, Value);
            undefined -> application:unset_env(quod, node_pubkey)
        end
    end.

operation_genesis(Ns, #{pubkey := Key}) ->
    Tx = quod_simplex:test_genesis_tx(#{node_id => Key, mode => create, committee => [],
      node_addr => {"127.0.0.1", 34249}}, Ns, Key, crypto:hash(sha256, <<243:64>>)),
    {ok, Genesis} = quod_ledger:new_entry(1, {batch, [Tx]}, 0, none),
    Anchor = operation_entry_hash(Genesis),
    {ok, [_], Projection} = quod_catchup:verify_forward(
      Ns, Anchor, quod_simplex:history_projection({Ns, Anchor}), 1, [Genesis]),
    {{Ns, Anchor}, Genesis, Projection}.

entry({Ns, Anchor}, Signer = #{pubkey := Key}, Slot, Tx) ->
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [Tx]}, Slot),
    Hash = quod_simplex:block_hash(Block),
    #share{sig = Signature} = quod_simplex:make_share(
      quod_simplex:consensus_domain(Ns, Anchor), commit, Slot, Hash, Signer),
    quod_ledger:entry(Block, #cert{kind = commit, slot = Slot, block_hash = Hash,
                                 sigs = [{Key, Signature}]}).

operation_entry_hash(Entry) ->
    {ok, Block} = quod_ledger:block_from_entry(Entry), quod_simplex:block_hash(Block).

view(Store, Projection, Entry) ->
    Ns = quod_ledger_store:namespace(Store), Height = quod_ledger_store:last(Store),
    #{owner => quod_reg:where({quod_simplex, Ns}),
      identity => maps:get(target, maps:get(dtx, Projection)), slot => Height, applied => Height,
      snapshot => quod_ledger_store:snapshot(Store),
      projection => Projection#{history_head => {Height, operation_entry_hash(Entry)},
                                 timestamp => Height}}.

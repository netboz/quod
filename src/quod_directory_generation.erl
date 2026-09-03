-module(quod_directory_generation).
-moduledoc """
Canonical signed page of one node's complete directory generation.

The same page format is used for live publication and resynchronization.  A
receiver must assemble every page of a generation before installing any of
its descriptors.  Page size is bounded; the number of pages, and therefore
the number of hosted ontologies, is not a policy limit.
""".

-export([sign/9, sign_generation/7, decode/1, assemble/2,
         validate_projection/3, validate_node_projection/2,
         author/1, node_key/1, endpoint/1,
         epoch/1, generation/1, page/1, last/1, hosted/1]).

-include("quod_directory_limits.hrl").

-define(VERSION, 1).
-define(MAX_BYTES, 16 * 1024).

-type author() :: {node_actor, binary()} |
                  {root_bootstrap, <<_:256>>, <<_:256>>}.
-type descriptor() :: {binary(), <<_:256>>, validator | observer,
                       bootstrap | system | node}.
-type page() :: #{author := author(), node_key := <<_:256>>,
                  endpoint := term(), epoch := non_neg_integer(),
                  generation := non_neg_integer(), page := non_neg_integer(),
                  last := boolean(), hosted := [descriptor()]}.

-spec sign(author(), <<_:256>>, term(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), boolean(), [descriptor()], term()) ->
          {ok, binary()} | {error, term()}.
sign(Author, NodeKey, Endpoint, Epoch, Generation, Page, Last, Hosted, Signer) ->
    case validate(Author, NodeKey, Endpoint, Epoch, Generation,
                  Page, Last, Hosted) of
        {ok, Canonical} ->
            Body = body(Author, NodeKey, Endpoint, Epoch, Generation,
                        Page, Last, Canonical),
            Signature = quod_identity:sign(Body, Signer),
            Encoded = term_to_binary(
                        {quod_directory_generation, ?VERSION, Body, Signature},
                        [deterministic]),
            case byte_size(Encoded) =< ?MAX_BYTES of
                true -> {ok, Encoded};
                false -> {error, too_large}
            end;
        {error, _} = Error -> Error
    end.

-doc "Split and sign one complete sorted generation into byte-bounded pages.".
-spec sign_generation(author(), <<_:256>>, term(), non_neg_integer(),
                      non_neg_integer(), [descriptor()], term()) ->
          {ok, [binary()]} | {error, term()}.
sign_generation(Author, NodeKey, Endpoint, Epoch, Generation, Hosted, Signer) ->
    case quod_directory_shape:validate_hosted(Hosted) of
        {ok, Hosted} ->
            case split_pages(Author, NodeKey, Endpoint, Epoch, Generation,
                             Hosted, Signer, 0, [], []) of
                {ok, Chunks} ->
                    sign_chunks(Author, NodeKey, Endpoint, Epoch, Generation,
                                Chunks, Signer, 0, []);
                {error, _} = Error -> Error
            end;
        _ -> {error, bad_generation}
    end.

split_pages(_Author, _NodeKey, _Endpoint, _Epoch, _Generation, [], _Signer,
            _Index, [], []) -> {ok, [[]]};
split_pages(_Author, _NodeKey, _Endpoint, _Epoch, _Generation, [], _Signer,
            _Index, Current, Acc) ->
    {ok, lists:reverse([lists:reverse(Current) | Acc])};
split_pages(Author, NodeKey, Endpoint, Epoch, Generation,
            [Descriptor | Rest], Signer, Index, Current, Acc) ->
    Candidate = lists:reverse([Descriptor | Current]),
    case sign(Author, NodeKey, Endpoint, Epoch, Generation, Index, false,
              Candidate, Signer) of
        {ok, _} ->
            split_pages(Author, NodeKey, Endpoint, Epoch, Generation, Rest,
                        Signer, Index, [Descriptor | Current], Acc);
        {error, too_large} when Current =/= [] ->
            split_pages(Author, NodeKey, Endpoint, Epoch, Generation,
                        [Descriptor | Rest], Signer, Index + 1, [],
                        [lists:reverse(Current) | Acc]);
        {error, _} = Error -> Error
    end.

sign_chunks(_Author, _NodeKey, _Endpoint, _Epoch, _Generation, [], _Signer,
            _Index, Acc) -> {ok, lists:reverse(Acc)};
sign_chunks(Author, NodeKey, Endpoint, Epoch, Generation, [Chunk | Rest],
            Signer, Index, Acc) ->
    Last = Rest =:= [],
    case sign(Author, NodeKey, Endpoint, Epoch, Generation, Index, Last,
              Chunk, Signer) of
        {ok, Encoded} ->
            sign_chunks(Author, NodeKey, Endpoint, Epoch, Generation, Rest,
                        Signer, Index + 1, [Encoded | Acc]);
        {error, _} = Error -> Error
    end.

-spec decode(term()) -> {ok, page()} | {error, term()}.
decode(Encoded) when is_binary(Encoded), byte_size(Encoded) =< ?MAX_BYTES ->
    case quod_safe_term:decode(Encoded, ?MAX_BYTES) of
        {ok, {quod_directory_generation, ?VERSION, Body, Signature}}
          when is_binary(Body), is_binary(Signature),
               byte_size(Signature) =:= 64 ->
            decode_body(Body, Signature);
        _ -> {error, bad_generation}
    end;
decode(Encoded) when is_binary(Encoded) -> {error, too_large};
decode(_) -> {error, bad_generation}.

-doc "Validate a node-authored generation against exact certified facts.".
-spec validate_node_projection(page(), map()) -> ok | {error, term()}.
validate_node_projection(Page, Clauses) when is_map(Page), is_map(Clauses) ->
    case author(Page) of
        {node_actor, Blob} ->
            case quod_agent_ref:decode(Blob) of
                {ok, #{instance := Instance, reference := NodeRef}} ->
                    KeyFact = {agent_key, Instance, node_key(Page), active},
                    HostFacts =
                        [{hosts_ontology, NodeRef, Ns, Anchor, discoverable}
                         || {Ns, Anchor, _Role, node} <- hosted(Page)],
                    case exact_facts([{agent_key, 3}, {hosts_ontology, 4}],
                                     Clauses) of
                        {ok, Facts} ->
                            case lists:member(KeyFact, Facts) andalso
                                 lists:all(
                                   fun(Fact) -> lists:member(Fact, Facts) end,
                                   HostFacts) of
                                true -> ok;
                                false -> {error, unauthorized_generation}
                            end;
                        error -> {error, bad_projection}
                    end;
                _ -> {error, bad_generation}
            end;
        _ -> {error, bad_generation}
    end;
validate_node_projection(_, _) -> {error, bad_projection}.

-doc "Validate every descriptor against its one committed authority.".
-spec validate_projection(page(), map(), [{binary(), <<_:256>>}]) ->
          ok | {error, term()}.
validate_projection(Page, Clauses, Catalog) when is_list(Catalog) ->
    Hosted = hosted(Page),
    case validate_catalog_rows(Hosted, Catalog) of
        ok ->
            case author(Page) of
                {node_actor, _} ->
                    case lists:any(
                           fun({_Ns, _Anchor, _Role, Source}) ->
                               Source =/= node
                           end, Hosted) of
                        true -> {error, unauthorized_generation};
                        false -> validate_node_projection(Page, Clauses)
                    end;
                {root_bootstrap, RootAnchor, AuthorKey} ->
                    PageKey = node_key(Page),
                    case lists:all(
                           fun({<<"quod:root">>, Anchor, _Role, bootstrap}) ->
                                   Anchor =:= RootAnchor;
                              ({_Ns, _Anchor, _Role, system}) -> true;
                              (_) -> false
                           end, Hosted) of
                        true when AuthorKey =:= PageKey -> ok;
                        _ -> {error, unauthorized_generation}
                    end
            end;
        Error -> Error
    end;
validate_projection(_, _, _) -> {error, bad_projection}.

validate_catalog_rows(Hosted, Catalog) ->
    case lists:all(
           fun({Ns, Anchor, _Role, system}) ->
                   lists:member({Ns, Anchor}, Catalog);
              ({_Ns, _Anchor, _Role, _Source}) -> true
           end, Hosted) of
        true -> ok;
        false -> {error, unauthorized_generation}
    end.

exact_facts(Functors, Clauses) ->
    try
        {ok, lists:append(
               [[Head || {Head, {[], false}} <- maps:get(Functor, Clauses)]
                || Functor <- Functors])}
    catch _:_ -> error
    end.

-doc "Add one decoded page to an incomplete generation assembly.".
-spec assemble(page(), undefined | map()) ->
          {pending, map()} | {complete, page()} | {error, term()}.
assemble(Page, undefined) ->
    assemble(Page, new_assembly(Page));
assemble(Page, Assembly) when is_map(Page), is_map(Assembly) ->
    case assembly_relation(Page, Assembly) of
        newer -> assemble(Page, new_assembly(Page));
        stale -> {error, stale_generation};
        mismatch -> {error, generation_mismatch};
        current -> put_assembly_page(Page, Assembly)
    end;
assemble(_, _) -> {error, bad_generation}.

new_assembly(Page) ->
    #{author => author(Page), node_key => node_key(Page),
      endpoint => endpoint(Page), epoch => epoch(Page),
      generation => generation(Page), pages => #{}, last_page => undefined}.

assembly_relation(Page, #{author := Author, node_key := NodeKey,
                          endpoint := Endpoint, epoch := Epoch,
                          generation := Generation}) ->
    case {author(Page) =:= Author, node_key(Page) =:= NodeKey,
          endpoint(Page) =:= Endpoint} of
        {true, true, true} ->
            case {epoch(Page), generation(Page)} of
                {Epoch, Generation} -> current;
                {PageEpoch, _} when PageEpoch > Epoch -> newer;
                {Epoch, PageGeneration} when PageGeneration > Generation -> newer;
                {PageEpoch, _} when PageEpoch < Epoch -> stale;
                {Epoch, PageGeneration} when PageGeneration < Generation -> stale
            end;
        _ -> mismatch
    end.

put_assembly_page(Page, Assembly = #{pages := Pages, last_page := Last0}) ->
    Index = page(Page),
    EncodedPage = page_identity(Page),
    case maps:get(Index, Pages, undefined) of
        undefined ->
            case merge_last(Index, last(Page), Last0) of
                {ok, Last1} ->
                    finish_assembly(
                      Assembly#{pages := Pages#{Index => {EncodedPage, Page}},
                                last_page := Last1});
                error -> {error, conflicting_last_page}
            end;
        {EncodedPage, _} -> finish_assembly(Assembly);
        _ -> {error, conflicting_page}
    end.

merge_last(Index, true, undefined) -> {ok, Index};
merge_last(Index, true, Index) -> {ok, Index};
merge_last(_Index, true, _Other) -> error;
merge_last(Index, false, Last) when is_integer(Last), Index >= Last -> error;
merge_last(_Index, false, Last) -> {ok, Last}.

finish_assembly(Assembly = #{last_page := undefined}) -> {pending, Assembly};
finish_assembly(Assembly = #{pages := Pages, last_page := Last}) ->
    case map_size(Pages) =:= Last + 1 andalso
         lists:all(fun(I) -> maps:is_key(I, Pages) end,
                   lists:seq(0, Last)) of
        false -> {pending, Assembly};
        true ->
            Ordered = [maps:get(I, Pages) || I <- lists:seq(0, Last)],
            Hosted = lists:append([hosted(P) || {_Identity, P} <- Ordered]),
            case quod_directory_shape:validate_hosted(Hosted) of
                {ok, Hosted} ->
                    {_Identity, First} = hd(Ordered),
                    {complete, First#{page := 0, last := true, hosted := Hosted}};
                _ -> {error, bad_generation}
            end
    end.

page_identity(Page) ->
    {author(Page), node_key(Page), endpoint(Page), epoch(Page),
     generation(Page), page(Page), last(Page), hosted(Page)}.

decode_body(Body, Signature) ->
    case quod_safe_term:decode(Body, ?MAX_BYTES) of
        {ok, {quod_directory_generation_body, ?VERSION, Author, NodeKey,
              Host, Port, Epoch, Generation, Page, Last, Hosted}} ->
            Endpoint = {Host, Port},
            case validate(Author, NodeKey, Endpoint, Epoch, Generation,
                          Page, Last, Hosted) of
                {ok, Canonical} ->
                    CanonicalBody = body(
                                      Author, NodeKey, Endpoint, Epoch,
                                      Generation, Page, Last, Canonical),
                    case Body =:= CanonicalBody andalso
                         quod_identity:verify(Signature, Body, NodeKey) of
                        true ->
                            {ok, #{author => Author, node_key => NodeKey,
                                   endpoint => Endpoint, epoch => Epoch,
                                   generation => Generation, page => Page,
                                   last => Last, hosted => Canonical}};
                        false -> {error, bad_signature}
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, bad_generation}
    end.

body(Author, NodeKey, {Host, Port}, Epoch, Generation, Page, Last, Hosted) ->
    term_to_binary(
      {quod_directory_generation_body, ?VERSION, Author, NodeKey, Host, Port,
       Epoch, Generation, Page, Last, Hosted}, [deterministic]).

validate(Author, NodeKey, Endpoint, Epoch, Generation, Page, Last, Hosted)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32,
       is_integer(Epoch), Epoch >= 0,
       is_integer(Generation), Generation >= 0,
       is_integer(Page), Page >= 0,
       is_boolean(Last), is_list(Hosted) ->
    case valid_author(Author) andalso quod_quic:valid_endpoint(Endpoint) of
        false -> {error, bad_generation};
        true ->
            case quod_directory_shape:validate_hosted(Hosted) of
                {ok, Hosted} -> {ok, Hosted};
                {ok, _NonCanonical} -> {error, bad_generation};
                error -> {error, bad_generation}
            end
    end;
validate(_, _, _, _, _, _, _, _) -> {error, bad_generation}.

valid_author({node_actor, Blob}) when is_binary(Blob) ->
    case quod_agent_ref:decode(Blob) of {ok, _} -> true; _ -> false end;
valid_author({root_bootstrap, <<_:256>>, <<_:256>>}) -> true;
valid_author(_) -> false.

author(Value) -> maps:get(author, Value).
node_key(Value) -> maps:get(node_key, Value).
endpoint(Value) -> maps:get(endpoint, Value).
epoch(Value) -> maps:get(epoch, Value).
generation(Value) -> maps:get(generation, Value).
page(Value) -> maps:get(page, Value).
last(Value) -> maps:get(last, Value).
hosted(Value) -> maps:get(hosted, Value).

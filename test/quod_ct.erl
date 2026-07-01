-module(quod_ct).
-moduledoc """
Shared Common Test helpers, extracted from the per-suite copies (deferred cleanup #1).

These four were byte-identical across the CT suites, so they live here once and are pulled in
via `-import(quod_ct, [...])` so call sites read unchanged (`eventually(F, T)`, `stop_all(Ps)`, …).
Helpers that genuinely vary per suite — node boot (`start_peer`/`start_member`), the self-signed
dev cert (`make_cert`, whose CN differs), and the `?NS`-bound query helpers (`status`/`role`/`prove`)
— stay in their suites. `replica_SUITE` keeps its own slightly-different `eventually`/`match_ok`/
`datadir` variants.
""".
-include_lib("common_test/include/ct.hrl").
-export([eventually/2, stop_all/1, match_ok/1, datadir/2]).

%% Poll `F` every 150ms until it returns `true` or the budget runs out.
eventually(_F, Timeout) when Timeout =< 0 -> false;
eventually(F, Timeout) ->
    case (catch F()) of
        true -> true;
        _    -> timer:sleep(150), eventually(F, Timeout - 150)
    end.

%% Best-effort stop of a list of `peer` nodes (never throws).
stop_all(Peers) -> _ = [catch peer:stop(P) || P <- Peers], ok.

%% A `quod_prolog:prove/3` result with at least one binding.
match_ok({ok, [_ | _], _}) -> true;
match_ok(_)                -> false.

%% A per-port data_dir under the suite's private dir.
datadir(Config, Port) -> filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)).

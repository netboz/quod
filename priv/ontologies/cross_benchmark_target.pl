%% Target side of the opt-in cross-ontology benchmark topology.
%%
%% Use benchmark_echo(ok) as the default meaningful remote-read workload. It
%% remains a read, so cross-ontology load does not affect consensus throughput.

can_read(_Goal, _Subject, _Ns).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

benchmark_echo(ok).

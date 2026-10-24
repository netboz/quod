# Invocation failure

The command supplied `/0` in rebar3's generator option. Rebar3 treated it as
part of the function name and cancelled the test before execution. No domain
assertion ran. Preserve this exit-1 receipt; the next distinct run uses the
generator name without the arity suffix.

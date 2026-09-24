# quod — notes for Claude

A Prolog/Brahms P2P node over QUIC (pure-Erlang `quic`, no NIF), no broker. See `README.md`.

## Shared working agreement

Read and follow [AGENTS.md](AGENTS.md) before working or reviewing. It is the
single source for Yan's engineering rules, continuity and evidence requirements.
Require delegated agents to read it too; do not maintain a second copy here.

## `AI:` markers

Inline `AI:` comments are change requests. When asked to "do the AI comments",
grep for `AI:` across the relevant scope, apply each change at its location,
then remove the marker (unless told to keep it).

## Conventions

- Erlang docs use OTP 27+ `-moduledoc`/`-doc` **Markdown** attributes, not EDoc
  `%% @doc`. Use real Markdown (sections, lists, code fences, tables, `m:module`
  links); don't mechanically tag every comment — only module docs + public API.

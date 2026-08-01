# Unified ontology-creation inputs

## Goal

Keep one ontology-creation operation and make its second argument an ordered
list of input options. The node-local authorized action entry is:

```erlang
quod_prolog:run_action(
  <<"quod:root">>,
  {create_ontology, {':', user, notes},
   [{source_file, "./test.pl"},
    {source_file, "./test2.pl"},
    {source, "note(inline)."}]}).
```

The corresponding Erlang representation is:

```erlang
quod_ontology:create(
  {':', user, notes},
  [{source_file, "./test.pl"},
   {source_file, "./test2.pl"},
   {source, <<"note(inline).">>}]).
```

This was a breaking replacement for the former raw term-list argument. There
is no `create_source/2`, legacy argument detection, or compatibility branch.
All inputs converge before validation and use the existing atomic creation
path.

## Options

`create/2` accepts a proper list containing these options:

- `{source_file, Path}` reads and parses every Prolog term in `Path`.
- `{source, Text}` parses every Prolog term in an in-memory UTF-8 source.
- `{terms, Terms}` accepts a proper list of terms already in Erlog's Erlang
  representation. This is useful to Erlang callers and for ground facts passed
  through Prolog.

`Path` is a non-empty binary or character list. `Text` is a UTF-8 binary or
character list; Prolog double-quoted values naturally arrive as character
lists. Both shapes are normalised once at the option boundary.

All three options may occur more than once. Their terms are combined in exact
option order and exact source order. An empty option list deliberately creates
an ontology with only its generated incarnation and founding-member facts.
Unknown options, malformed tuples, improper option or term lists, invalid
UTF-8 source, and invalid path values fail as `invalid_options`.

The list is intentionally not converted to a map: repeated sources and their
order are meaningful, and later options such as identity or visibility need
not change the input-loading pipeline.

The lifecycle action runner requires the complete action to be ground.
Consequently `{terms, Terms}` can carry ground facts in the action term but not
clauses containing caller variables. `source/1` and `source_file/1` are the
normal way to supply rules: variables are parsed as data inside the source,
not mistaken for variables of the action request.

## One creation pipeline

`quod_ontology:create/2` performs these steps:

1. Canonicalise and validate the namespace exactly as it does now.
2. Walk the option list once from left to right. Load each option into terms
   and append it to a reverse accumulator with `lists:reverse/2`; reverse once
   at the end. No repeated `++` or quadratic concatenation is introduced.
3. Reject caller definitions of `consensus_incarnation/1` and
   `peer_admitted/4` across the combined terms.
4. Pre-compile the combined terms with `quod_prolog:terms_to_diff/1`.
5. Pass those same terms as `genesis_terms` through the existing
   `build_ns_config/1`, `start_new_content/2`, and
   `quod_simplex:genesis_tx/4` path.
6. Return the existing `{ok, created | resumed, Namespace, GenesisHash}` shape.

Every option is loaded, parsed, validated, and pre-compiled before
`root_storage/0`, ledger probing, or the namespace-manager call. A bad later
source therefore cannot leave a partially created ontology, desired entry,
retry timer, or ledger directory. Reading an explicitly requested source file
is the only filesystem action before that boundary and never mutates it.

Resume keeps the current explicit semantics: options are still validated, but
an existing slot-1 ledger is returned as `resumed` and is not rewritten with
new terms.

The existing restrictions remain unchanged: all `quod` system namespaces are
reserved, creation is local and self-founded, no directory advertisement or
durable hosting manifest is added, and successful creation publishes the data
directory only after obtaining its genesis anchor.

## Erlog parsing primitive

Source parsing belongs in Erlog, not in the ontology lifecycle module.

Add:

```erlang
erlog_io:read_string_terms(String) ->
    {ok, [term()]} | {error, {Line, Module, Detail}}.
```

It repeatedly drives `erlog_scan:tokens/3` over one character list and parses
each completed token sequence with `erlog_parse:term/2`. When the source ends
inside a scanner continuation, it feeds `eof` and applies the shared final-dot
normalisation described below; it does not copy the source merely to append
whitespace. It preserves source order and accepts zero or more dot-terminated
terms. It shares the scanner/parser behavior used by `read_file/1`; it does not
create a temporary file or a second Prolog parser.

As in Erlog's existing file reader, a literal `end_of_file.` term ends that
input immediately; any terms following it in the same source are ignored.

`erlog_parse:term/2` currently ignores its line argument and emits the legacy
line `9999` for end-of-input failures. Replace a reported line only when it is
exactly that sentinel; never key substitution only on the error detail, because
`{expected, Token}` can also carry a genuine mid-source token line. Change
`erlog_io:read_stream/2` to pass the scanner's returned ending line, not the
term's starting line. Genuine scanner/parser lines remain untouched. This
gives file and in-memory sources the same accurate line behavior.

Erlog's stream scanner also returns a final `.` at physical EOF as the atom
`'.'`, because its full-stop lexer rule requires following layout. Normalise
that one trailing scanner token to the full-stop token in Erlog's shared
`scan_erlog_term/3` boundary. This fixes `read_file/1` and interactive reads at
the source rather than adding a Quod file workaround; dots followed by layout
and graphic operators remain unchanged.

Quod converts binary source to a Unicode character list before calling this
primitive. File inputs reuse `erlog_io:read_file/1`, so existing consult-path
and file parsing behavior remain the single implementation. A bare
`end_of_file.` term stops both file and in-memory parsing, preserving Erlog's
existing consult behavior. Relative file paths use Erlog's `consult_path`
(default `["."]`, the release process working directory); operators should use
absolute paths when that location is not deliberately controlled.

The generated untracked `src/erlog_scan.erl` in the Erlog clone is not source
for this change; only tracked parser/I/O sources are edited.

## Errors and failure reasons

The Erlang API retains operator detail and identifies the failing option:

```erlang
{error, {source_error, OptionIndex, Line, Detail}}
{error, {source_file_error, OptionIndex, Path, Reason}}
{error, invalid_options}
```

`OptionIndex` is one-based. Scanner/parser modules and details remain Erlang
API diagnostics; file paths remain local operator diagnostics.
The option loader handles every documented `erlog_io:read_file/1` result:
`{ok, Terms}`, `{error, Reason}`, `{error, einval, Reason}`, and
`{exit, einval, Reason}`. The two crash-shaped results are detailed file errors,
never a `case_clause` escape.

Its lifecycle-specific input failures use bounded, portable reasons:

```prolog
ontology_creation_failed(invalid_options)
ontology_creation_failed(invalid_initial_terms)
ontology_creation_failed(invalid_source(OptionIndex, Line))
ontology_creation_failed(source_file_error(OptionIndex))
```

All existing name, root-only, protected-fact, and start-failure mappings remain
available. No raw source, path, parser detail, PID, or interpreter state enters
the Prolog failure stack.

`source_file/1` is reachable from the authorized lifecycle path only
through the dedicated root action runner. That runner derives a private node
principal, proves policy in a read-only committed view, re-authorizes, and then
calls the typed executor. Ordinary proofs, served cross-ontology asks,
consensus projections, and the explorer prove endpoint cannot execute it. The
low-level creation API is trusted same-VM code and is not a remote
authorization boundary.

## Tests

### Erlog

1. `read_string_terms/1` parses several facts and rules, preserving order and
   variables.
2. Empty source returns `{ok, []}`.
3. A final dot with no trailing whitespace is accepted.
4. Scanner and parser failures report their real multiline source line.
5. Missing dot, missing term, and missing closing token use the actual ending
   line instead of `9999`.
6. A mid-file token mismatch such as `foo(a b).` retains its genuine token line
   rather than being replaced by the source ending line.
7. Existing `read_file/1` gains the same ending-line assertions without
   changing successful results, and accepts a final dot at physical EOF.

### Quod

1. A mixed ordered list of `terms`, two `source_file` entries, and `source`
   produces one genesis containing every clause in order.
2. A source rule containing variables can be queried after creation.
3. The action runner accepts the same option list and creates that rule; the
   former raw term-list call is rejected as `invalid_options`.
4. A missing file, invalid UTF-8 source, malformed option, improper list, and
   syntax error in a later source leave the desired map, child set, explorer
   map, and namespace directory unchanged.
5. Errors identify the correct one-based option and source line, while the
   Prolog reason contains no path or raw parser detail.
6. Protected generated clause heads are rejected whether they arrive through
   `terms`, inline source, or a file.
7. Repeated file/source options prove order is preserved without a duplicate
   option being discarded.
8. Existing collision, failed-admission, resume, root-only action, authorization, and staged-write
   tests remain green under the new option shape.

Run focused Erlog and Quod tests first, then compile, xref, Dialyzer, full
EUnit, and full CT.

The Erlog parser change is developed on a new feature branch from its public
`quod` branch, reviewed and committed there, then merged into and pushed on the
Erlog `quod` branch. Quod updates both its dependency reference and lock entry
to that public commit, so a clean Docker build proves the pin is reproducible.
Quod then uses its two normal commits (feature, then patch release bump). Do
not commit or push either repository before review.

## Non-goals

- No second creation API or compatibility path.
- No new manifest, catalogue, ACL default, directory advertisement, identity,
  payment, quota, atom-accounting, deletion, or remote-hosting design.
- No file watching, include directive, module system, or automatic source
  reload.
- No new source-size or atom quota in this slice. As with boot's existing
  `genesis_file`, the root operator is trusted not to construct an impractically
  large slot-1 block; resource accounting remains a separate design.
- No change to consensus ordering, genesis composition, or the namespace
  manager beyond passing the combined validated terms through the existing
  path.

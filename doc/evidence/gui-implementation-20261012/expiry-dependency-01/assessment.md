# Independent assessment

Accepted R1, R3-R6: absence must be through the captured prefix, not against
retained future rows; trusted source/network context cannot come from embedded
request bytes; timestamps share ordered outcome flush/publication; every returned
negative needs a captured dependency and every unavailable result keeps the veto.
The source admission tests and code trace support the narrow theorem, not yet
an implementation or full recovery proof.

R2 needs narrowing. A different digest already claimed at/before the prefix is
not absence and must never return expired. Existing positive terminal observation
records its positive dependency then fails on a digest mismatch. A nonterminal
claim stays unavailable under the current public contract. Do not introduce a
new terminal conflict result without its own validator-checkable dependency;
this change will retain that conservative behavior. No GUI automatic request
reuse is permitted, so competing same-key intent is not an ordinary GUI path.

The unverified era detail was traced independently: advance_archive_custody's
terminal membership branch retains {Root,MaterialTs}; engine_root reads the
archive_tip timestamp; eng_new installs it as root_timestamp. eng_prune also
keeps the committed root block timestamp. No zero reset at era transition.
A production-era regression is still required for the negative dependency.

Read-only certification must also resolve trusted network context; it does not
enter content/4, so merely changing requires_network_identity over transactions
is insufficient. Audit that entry plus ordinary apply and atomic prepare together.
The projection's second OCC check also needs the same context, without token-
supplied network identity. Time rows will be immutable and retained through
replay, compared before reuse and inaccessible above the published floor.
No format change, expiry answer or automatic recovery has been implemented yet.

# Founding failure

The fixture stops before domain assertions: `genesis_failed, invalid_generated_genesis`.
The independent `composition-01` measurement uses all eleven production source
files and the normal generated genesis header, with no test owner facts. It
reports 339,337 canonical diff bytes; `encode_ledger_transaction/1` returns
`{error,too_large}`. The shared transaction envelope is limited to 262,272 bytes
and the containing block to 262,144 bytes. The initial ETF diff is only 130,314
bytes, below the 196,608-byte initial-source check: the later canonical encoding
is what exceeds the bound in this fixture. No cap has been changed.

There is also a separate public-founding admission problem: 516 cold symbols
against the current 512 allocation limit. This is a resource-allocation policy,
not the width of the symbol encoding. The count depends on the release vocabulary;
the measurement receipt and manifest identify the tested source. Loading test
modules first is not a solution for cold join/restart.

Both problems occur before the owner facts and lobby geometry are added. They
are not caused by the naming table, which lives in its separate existing system
ontology and is asked through its anchor. Do not split the founding transition,
increase constants, preload atoms, or trim supported world functionality to
make this fixture appear green. A shared composition/encoding/admission decision
is required before the actual create/enter journey can be validated.

The failed log and receipt are retained. No repeat of this integration test is
claimed to pass. No full clean campaign has started for the library integration.

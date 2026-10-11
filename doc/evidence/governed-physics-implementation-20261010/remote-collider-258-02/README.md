# Remote collider campaign 02: founding custody limit

Campaign 02 stopped before its first measurement world was founded. It used
existing source-text founding options to correct campaign 01's variable error.
Local construction and parsing checks passed. A first local check selected
stale default-profile beams and failed without network work; its result and
the corrected test-profile run remain separately recorded.

The actual production proof returned
`{error,{erlog,{system_error,invalid_prepared_effect}}}`.
Read-only authorized structural preparation identified the underlying result:
`{error,initial_content_too_large}`. The measured preparation occupies 304,774
raw ETF bytes: the 65,222-byte initial diff plus a 238,974-byte prepared genesis
entry and configuration. The existing prepared custody bound is 262,144 bytes.
The original action itself encodes to only 2,097 bytes.

The exact candidate root remains at applied height 62 and the intended world
remains `not_hosted`. No creation grant or signed collider operation was reached.
Both the original STOP and actual child exit 1 are retained. This campaign
establishes neither remote propagation nor desktop collision acceptance.

The next work is to inspect repeated representations in the existing lifecycle
custody owner and its canonical ledger codec. Do not raise a constant, split a
domain transition, rewrite history, or resubmit an uncertain operation.

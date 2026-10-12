# Native dependency audit, 2026-10-12

Official crate metadata still reports Parry 0.31.1 as latest stable. Its published
archive SHA256 is `7b626edc0b497dba4bdf6e1e0797895294ed9f61dac2bd28cb5d34d37ad2ca7e`.
Cargo uses that vendored release with the recorded minimal GJK correction. The
upstream Apache license is retained; package versions are unchanged.

The pinned official RustSec database is
`7eebec69c352c7191b1f13eb95dd510eeca5d1de`. Every one of the **69** locked package
names was checked. [All 12 name matches](rustsec-matches.json) satisfy an explicit
patched version range, as shown by the [range review](range-review.json).
This is a captured package/range check, not a `cargo audit` invocation or proof
against unknown vulnerabilities. The library algorithm patch was reviewed separately.

The frozen Claude request incorrectly said 64 packages, copied from the older
audit; the actual current scan covered all 69. Its erratum is retained without
rewriting the review input.

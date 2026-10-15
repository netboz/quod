# Minimal-scope solution consultation

Yan requested a definitive plan elaborated with Claude Fable, then emphasized
reusing the existing implementation and keeping changes small.

- `solution-consult-01`: failed before model execution with DNS ENOTFOUND;
  preserved exit 1 and API error. No review verdict.
- [solution-consult-02](solution-consult-02/fable-consultation.md): completed
  with exit 0 against unchanged frozen inputs. Fable agrees that the existing
  signed account journal removes the need for a server-only first-host lifecycle.
- `solution-consult-03`: interrupted; its stop record remains preserved.
- [solution-consult-04](solution-consult-04/fable-consultation.md): completed
  with exit 0 against unchanged frozen inputs. Fable supports bounded receipt
  retention in the existing vault and identified four verification conditions,
  covered in [the implementation obligations](../implementation-obligations.md).
  The earlier proposal to allow fresh outer-store attempts after unknown
  outcomes remains rejected: domain exclusivity does not satisfy the standing
  no-uncertain-resubmission requirement.
- `codec-consult-01`: automatic approval review rejected the repository-material
  transfer before execution. Yan subsequently approved the relevant source
  sharing, and the separate implementation reviews completed. This rejected
  attempt supplies no model verdict.

Full frozen requests remain under `_build/lobby-redesign-20261015/` with matching
attempt names. No production code or deployed state was changed by consultation.

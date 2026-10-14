# Validation assessment

Gate01 stopped at client tests: 172 passed, 1 failed. The new adversarial test caught a real presentation validator defect: multiple-selection parsing checked the list head but discarded an improper tail. Server validation remains authoritative, but the client must refuse the malformed draft before submission. Reuse the existing ground/proper-list `readList` parser. Preserve the initial manifest/tree and failed gate. No build, server or browser ran in gate01.

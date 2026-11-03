# Linux package dependency preparation

This coordinator-only read audit advances preparation for [QUO-66](nimbalyst://QUO-66).
No packaging implementation, retirement, deployment, product execution or
acceptance credit occurred. [Readiness handoff](../../../nimbalyst-local/handoffs/godot-m5-readiness.md)
retains dependencies and the later cutover boundary.

The [audit result](linux-export-dependencies.json) hashes every one of the196
accepted candidate09 production export entries, then reads the16 actual ELF
objects through anonymous memory descriptors. The [inspection script](audit-production-export.py)
executes readelf only; it never launches the client and leaves no extracted
binary copies. The archive hash is bound to the verified immutable M4 snapshot.
The R1 diagnostic export is not used.

Recorded external DT_NEEDED names are the Linux loader, libc, libdl, libgcc_s,
liblttng-ust, libm, libpthread, librt and libstdc++. Across these objects the
maximum recorded required symbol versions are GLIBC_2.28, GLIBCXX_3.4.22 and
CXXABI_1.3.7. These are measured ELF requirements, not a claim of support for
every host with those versions. The union includes diagnostic/runtime objects;
later cold-host checks must establish which ones are actually loaded.

Runtime dlopen/plugin dependencies (including graphics/display/crypto facilities)
are outside this static inspection. The system Monado/OpenCV mismatch remains
separate from the production export's direct ELF dependency graph. A future
package must verify actual cold launch and the complete intended journey with
build tools absent. Any R2 product change requires its newly qualified export
and a refreshed audit before release. Hardware gaps and the retained shutdown
failures remain open; this preparation does not convert them into acceptance.

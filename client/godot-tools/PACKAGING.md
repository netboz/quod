# Private Linux packaging

Package an accepted complete self-contained export with `package.py`. Supply
its exact source/export manifest digest and an explicit extra-file manifest
containing the launcher, instructions, licences and engine provenance. The tool
checks the complete ordinary-file payload and hashes the bytes it archives;
extras cannot replace exports. It builds a deterministic tar/gzip with sorted
paths, fixed ownership/time and recorded executable modes. It never compiles,
installs, launches a runtime, changes a profile or deploys a service.

Run the extracted `quod` entry. Keep the full directory together; the entry
resolves its executable relative to itself and forwards arguments literally.
The package's manifest binds every payload/notices byte. Required system and
optional OpenXR dependencies are documented beside the executable. Private
fixture/profile data and diagnostic overlays do not belong in a package.

The M5 package checkpoint is qualified separately from server release,
retirement, network cutover and physical hardware acceptance.

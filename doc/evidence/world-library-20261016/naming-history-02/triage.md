# Cold diagnostic scan refusal

Adding dependency paths reaches the stopped ledger, but its strict scanner
refuses a proof block at offset 59,959. Do not label the file corrupt or count
this as a successful inspection. This standalone VM has not loaded the release
modules that embedded production loads before decoding fixed protocol atoms.

The next diagnostic will load exactly the application's declared BEAM modules,
without loading any ontology source or allocating its vocabulary. This checks
whether the failure is diagnostic setup or a real cold decoding defect. The
failed scan and receipt remain intact; no file repair is authorized.

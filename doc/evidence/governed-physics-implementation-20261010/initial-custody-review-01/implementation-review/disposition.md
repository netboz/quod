# Independent disposition

Claude Fable (`claude-fable-5-1`) completed the implementation review with child
exit 0 and 35 unchanged frozen inputs. It approved proceeding to the next gate,
with no blocking correctness finding. This is not release or live acceptance.

1. Accepted: installed local node references now materialize through the existing
   node actor owner. The bridge, runtime and custody worker share that helper;
   callers retain their own required key or unavailable-result checks.
2. Kept the destination check after custody preparation, with its reason stated:
   a node may withdraw while the vault is busy. The answer must not advertise an
   obsolete destination. Prepared custody remains inert and reusable.
3. Accepted: only paths entering a storage mutation mark durability uncertain.
   Stale, malformed and already-expired requests leave the flag unchanged; a
   failed mutation still requires a successful sync before reuse. The flag is
   resolved independently of an expired public reply, so a deadline cannot hide
   an uncertain write. Added real-owner storage tracing for unchanged rejections.
4. Accepted: recovery publication explicitly requires a positive previous epoch.
   The shared eligibility helper owns the exact assignment check. The recovery
   policy retains its positive-epoch permission restriction and eligible-host
   rule. Added a first-preparation grant test that still refuses epoch-zero
   recovery publication without a diff.
5. The existing signing-policy discipline is a separate follow-up, as the reviewer
   specified. This slice changes custody preparation, not signing authorization.
6. Existing fixture global-state and trace-internals assumptions remain confined
   to sequential tests, with delivery barriers and cleanup.

The clean campaign already running is preserved against its original frozen
inputs. Corrections have separately labelled tests and require final-tree release
verification. The first corrections command mistakenly named a nonexistent test
module; compilation passed but no tests ran. Its failed receipt is retained and
the subsequent command uses the actual module name.

Deployment inspection also found that the current Nomad nodes leave local vault
custody disabled. The deployment configuration now provisions one private unlock
file per durable node directory at prestart and enables the existing local vault.
The one shared script refuses malformed, insecure or symlinked existing files;
it preserves the existing inode and bytes on restart. Publication uses a synced
temporary file, an exclusive hard link and a directory sync. Neither secret
bytes nor agent keys enter logs, image layers or ontology facts. The separate
network vault provider remains disabled. This is operator provisioning of the
existing service, not a new domain lifecycle.

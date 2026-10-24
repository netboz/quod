# Update Wild Realm’s appearance

This request adds the authored sky and grass/ground textures to the existing **Wild Realm**, and updates the same lobby’s world-creation template. It preserves terrain generation, terrain changes, collisions, world ownership and movement settings. It uses the existing editing ontology and one ordinary atomic transaction.

After the corrected client release is deployed:

1. Reload Quod and select the account that owns Wild Realm.
2. Return to the personal lobby and choose **Open console**.
3. Copy the complete text from [wild-realm-appearance.pl](wild-realm-appearance.pl) into **Prolog goal**.
4. Choose **Run**, then **Accept solution** after a successful proof.
5. Return to the lobby, then enter Wild Realm again.

The source and appearance guards require the original default state. A changed or already-updated state is refused. Before committing, the same transaction checks every owned world through the complete existing world-view projection; an incomplete other sky refuses the entire update. If the proof fails, stop and retain its error; do not modify the guards. If an accepted operation reports uncertainty, use **Check saved outcome** for that operation instead of submitting it again.

The server operator cannot sign as the owner of this private lobby. The compiled appearance transition was independently reviewed by Fable and completed through an existing owner account with all terrain definitions unchanged. The complete final world-view check passed positive and negative staged proof tests, stopped without accepting changes, and was independently reviewed by Fable. The portable file retains that exact compiled transition and adds the final world-view check and uses the normal owner permission check. No private signing key is exported.

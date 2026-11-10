# Phase 2 documentation sentences

The sole normative document changed is [gui-examples.md](../../gui-examples.md).
The complete exact edit is in [documentation-review.patch](documentation-review.patch).
The plan, release preparation and validation evidence carry workflow status separately.

Removed:

> `image` and its `icon` subclass accept an `image` attribute containing
> `asset(Digest, <<"image/jpeg">>)`: the same lowercase SHA-256 reference used by
> existing scene textures.

Added:

> `image` and its `icon` subclass accept an `image` attribute containing
> `image(asset(Digest, Mime), resources(Transfer, Pixels))`, with PNG or JPEG
> bytes stored as `gui_asset(Digest, Mime, Bytes)` facts in `quod:gui`.
> The client reads each digest through the ordinary signed path, checks SHA-256
> and the authored byte/pixel allowances, and reuses the verified texture by digest.
> Changing `gui_icon/2` refreshes dependent live views through their existing
> installed-change subscriptions.

Removed:

> Both adapters reuse verified asset bytes and show loading/error feedback;
> resource leases end when their controls are retired.

Added:

> Godot reuses verified asset bytes; the existing browser adapters have not
> adopted this image shape.

The descriptive label, icon-button activation and absence of ontology image
URLs/client callbacks remain in the same paragraph. No other normative sentence
was edited. Plan §1 and §8 remain unchanged from the authorized commit.

Quod — private Linux x86-64 evaluation package

Extract the complete archive into a directory you own. Open a terminal there
and run ./quod. The supplied .NET runtime is self-contained: no Godot editor,
.NET SDK, Python builder, Chromium, or client compilation is needed.

Keep all files together. You may move the complete directory, including to a
path containing spaces. Run ./quod -- --profile /absolute/private/profile to
choose a separate profile. Without that argument the ordinary platform user
data directory is used. Profiles, active keys and backups are private user data;
they are never installed into or supplied by this package.

Enter your HTTPS node origin and its explicitly trusted CA when required.
The initial origin is https://localhost:14570; replace it with your intended
node. No service, account, sign-in, keys or fixture is installed by this package.
It does not install a server or replace a network. Reconnect resolves original
work; it never grants permission to repeat an uncertain operation.

For a desktop-only launch use ./quod --xr-mode off. Engine arguments precede
the -- separator; profile/node/CA arguments follow it, for example:
./quod --xr-mode off -- --profile "/absolute/private profile" --node https://your-node:14570 --ca /absolute/trusted-ca.pem
Use your real node and trust paths; no example endpoint or CA is bundled.
The server must provide the matching qualified space/world-name view contract
and GUI resources. Compatibility with an arbitrary older endpoint is not qualified.

On first run, follow the highlighted next action: Create my key, then Connect.
The account controls show only the next required step: Create my account,
Review starting space storage, or Create my agent and starting space. Returning
accounts recover the original identity and location. Active keys are protected
by private filesystem permissions; only portable backups use a passphrase.

Current space shows the current interior and its permitted, named contents.
Select a visible subject to inspect it. Views inspect; Actions open an offered
form and do not submit it. To create another space, use Create…, choose your
storage and the space class, review its name and other fields, then click Create
once. Selecting the result or its visible contents representation does not move
you. Choose Enter and confirm the offered form to move the same agent.
Current space returns home; Inspector recalls the selected subject and compatible
local draft. Space views & actions opens choices for the current place. More views
exposes additional inspection tools. An empty interior has no required floor or sky.

Inspect storage source opens that exact ontology. Choose Workbench, select a
class, instance or fact, then New class, Add text attribute or Edit selected
fact as appropriate. Prepare changes only the local Source draft. Read it,
Preview changes, then explicitly Save changes to commit. Cancel preview keeps
the draft. Sign in again explicitly recovers the same key after expiry;
disconnect/reopen resolves original work and never replays an uncertain write.
Unsubmitted source text is a private local draft, not a committed change. Reopening
its source inspector restores the draft; keep pending outcomes until resolved.

Authorized ontologies may supply the appearance of their offered forms and
workspaces. Local Larger text and Opaque preferences take precedence; essential
text, controls, status and the adjacent keyboard stay opaque. This native client
consumes those authored tokens. The browser currently accepts inherited defaults
and explicitly refuses authored non-inherit appearance.

Desktop requirements: Linux x86-64, a compatible Wayland or X11 desktop,
glibc 2.44+, libstdc++, graphics/OpenGL drivers with their EGL vendor data,
keyboard-layout/compose data, fonts, ICU, zlib and OpenSSL support.
These are dependency floors, not certification of every distribution. The
qualification record states the actual tested host and isolated launch scope.
OpenXR additionally needs a compatible installed runtime, Vulkan/display access
and actual hardware qualification. No runtime, drivers or Monado are bundled,
installed or started by this package. Start OpenXR only on a prepared host.

Optional local desktop launcher: create a .desktop file in your own applications
directory with Type=Application, Name=Quod, Terminal=false and Exec="/absolute/
path/to/quod-linux-x86_64/quod" (substitute the real path on one line). Do not
install system-wide. Remove only that desktop entry to undo this local step.

This is a private evaluation build, not a public release or a licence grant
for Quod. Third-party licence texts and the private engine patch provenance
are included in notices/. Physical placement/comfort and the complete mapped
controller journey remain separately unqualified.

Normal exits are qualified in the accompanying software record; intermittent
historical shutdown pauses remain unresolved. Desktop software checks do not
establish human usability, headset bootstrap or physical comfort.

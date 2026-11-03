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

After sign-in, the existing offered Create / operations form selects storage
and a space class. Explicit Submit creates a space; Open result and its Enter
offer enter it using the same personal agent. Source / inspection opens the
exact ontology's authored representations. Choose Workbench to inspect classes,
instances and facts; Prepare changes only a local draft, Preview checks it and
Save explicitly commits it. Cancel does not commit. Disconnect and Connect
retain identity/location and resolve original work rather than replaying it.
Keep unsubmitted drafts and pending outcomes until you deliberately resolve them.

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

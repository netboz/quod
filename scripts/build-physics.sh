#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cargo build --locked --release --manifest-path native/quod_physics/Cargo.toml
mkdir -p priv/native
case "$(uname -s)" in
  Linux) library=libquod_physics.so ;;
  Darwin) library=libquod_physics.dylib ;;
  *) echo 'Unsupported native physics build platform' >&2; exit 1 ;;
esac
# Never truncate an inode that a running BEAM may have mapped as native code.
physics_tmp=$(mktemp priv/native/.quod_physics.XXXXXX)
trap 'rm -f "$physics_tmp"' EXIT HUP INT TERM
cp "native/quod_physics/target/release/$library" "$physics_tmp"
chmod 755 "$physics_tmp"
mv -f "$physics_tmp" priv/native/quod_physics.so

# native/ — guest C binaries (not vendored)

`podroid-hostd`, `podroid-vsock-agent` and `podroid-overlay-normalize` are
built from the **sibling Podroid checkout** (default `../Podroid`, override
with `PODROID_SRC=...`) by `build/build-native.sh`:

```sh
PODROID_SRC=/path/to/Podroid ./build/build-native.sh
# -> native/staged/{podroid-hostd,podroid-vsock-agent,podroid-overlay-normalize}
```

They are plain C programs (guest side, musl-static in upstream). Building them
with the host toolchain is fine as long as they end up statically linked —
the build script warns when they are not.

Wire protocols / ports they implement (unchanged, see docs/COMPAT.md):
- host bridge: `/dev/hvc2` (QEMU) or AF_VSOCK 9101 (AVF), one-line req/resp
- vsock agent: control 9100, forwards per `/etc/podroid/forwards.conf`,
  downloads 9p rendezvous 200000

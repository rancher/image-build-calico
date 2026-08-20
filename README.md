# rancher/image-build-calico

This repo builds hardened, statically-linked Go binaries from
[projectcalico/calico](https://github.com/projectcalico/calico) and packages them in a minimal
SLE BCI ([bci-minimal](https://registry.suse.com/repositories/bci-bci-minimal-16-0)) based image.

Binaries are compiled against [`rancher/hardened-build-base`](https://github.com/rancher/image-build-base),
which provides the latest supported Go toolchain (FIPS/BoringCrypto-enabled on amd64).


## Public Images

- `rancher/hardened-calico` — consolidated Calico component binary

## PRIME Images
- `rancher/hardened-calico-node` — Calico node runtime image

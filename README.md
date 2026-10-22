# rancher/image-build-calico

This repo builds hardened, statically-linked Go binaries from
[projectcalico/calico](https://github.com/projectcalico/calico) and packages them in a minimal
SLE BCI ([bci-minimal](https://registry.suse.com/repositories/bci-bci-minimal-16-0)) based image.

Binaries are compiled against [`rancher/hardened-build-base`](https://github.com/rancher/image-build-base),
which provides the latest supported Go toolchain (FIPS/BoringCrypto-enabled on amd64).


## Public Images

- `rancher/hardened-calico` — consolidated Calico component binary; used by RKE2 Canal (Calico + Flannel)

## PRIME Images
- `rancher/hardened-calico-calico` — the same image as `rancher/hardened-calico`, complies with requirements set by the chart's `hardened-calico-` prefix
- `rancher/hardened-calico-node` — Calico node runtime image
- `rancher/hardened-calico-third-party-cni-plugins` — all plugins from `rancher/hardened-cni-plugins`, staged for the Calico CNI installer
- `rancher/hardened-calico-whisker` — Whisker UI assets served by nginx
- `rancher/hardened-calico-envoy-gateway` — Gateway API controller
- `rancher/hardened-calico-envoy-proxy` — Gateway API data-plane proxy
- `rancher/hardened-calico-envoy-ratelimit` — Gateway API rate-limit service

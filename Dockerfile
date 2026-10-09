ARG BCI_BUILD_IMAGE=registry.suse.com/bci/bci-base:16.0
# Only used for envoy-gateway and envoy-ratelimit
ARG BCI_NANO_IMAGE=registry.suse.com/bci/bci-nano:16.0
ARG BCI_RUNTIME_IMAGE=registry.suse.com/bci/bci-minimal:16.0@sha256:9099a5ae007bd9e41a287a3c24f115e49c2ae85316e1ef8a683b4e01fb936173
ARG GO_IMAGE=rancher/hardened-build-base:v1.27.2b1
ARG CNI_IMAGE_VERSION=v1.9.1-build20261008
ARG CNI_IMAGE=rancher/hardened-cni-plugins:${CNI_IMAGE_VERSION}
ARG GOEXPERIMENT=boringcrypto
# These are all tracked in upstreams metadata.mk file. UpdateCLI will automatically update these values based on the selected Calico TAG.
# Upstream derives this tag in metadata.mk as $(GO_VERSION)-llvm$(LLVM_VERSION)-k8s$(K8S_VERSION:v%=%).
ARG CALICO_GO_BUILD_IMAGE=calico/go-build:1.27.1-llvm21.1.8-k8s1.37.0
ARG BIRD_VERSION=v0.3.3-211-g9111ec3c
ARG BPFTOOL_IMAGE=calico/bpftool:v7.5.0
ARG ENVOYBINARY_IMAGE=quay.io/tigera/envoybinary:v1.39.1-9408962881
ARG CALICO_WHISKER_SOURCE_DIGEST=sha256:4802f246acbc4ac08d1ce6b5c229a518dc4d85e33b50b4d1366b05a49459497c
ARG TARGETARCH


FROM ${BCI_BUILD_IMAGE} AS bci
FROM ${BCI_RUNTIME_IMAGE} AS runtime_rootfs
FROM ${CNI_IMAGE} AS cni
FROM ${GO_IMAGE} AS builder
# setup required packages
ARG TAG
RUN set -x && \
    apk --no-cache add \
    bash \
    clang \
    curl \
    file \
    gcc \
    git \
    linux-headers \
    make \
    llvm \
    patch \
    libbpf-dev \
    libpcap-dev \
    libelf-static \
    zstd-static \
    zlib-static
RUN git clone --depth=1 https://github.com/projectcalico/calico.git $GOPATH/src/github.com/projectcalico/calico
WORKDIR $GOPATH/src/github.com/projectcalico/calico
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
COPY go-mod-overrides ./go-mod-overrides
RUN go-mod-overrides.sh ./go-mod-overrides
RUN sed -n 's/^LIBBPF_VERSION=//p' metadata.mk > /tmp/libbpf_version
RUN git clone https://github.com/libbpf/libbpf.git $GOPATH/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf
WORKDIR $GOPATH/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf
RUN git fetch --all --tags --prune
RUN LIBBPF_VERSION=$(cat /tmp/libbpf_version) && git checkout tags/${LIBBPF_VERSION} -b ${LIBBPF_VERSION}

### BEGIN K3S XTABLES ###
FROM builder AS k3s_xtables
ARG TARGETARCH
ARG K3S_ROOT_VERSION=v0.15.2
# Get xtables files from k3s-root
RUN mkdir -p /opt/xtables/
ADD https://github.com/k3s-io/k3s-root/releases/download/${K3S_ROOT_VERSION}/k3s-root-${TARGETARCH}.tar /opt/k3s-root/k3s-root.tar
# exclude 'mount' and 'modprobe' when unpacking the archive
RUN tar xvf /opt/k3s-root/k3s-root.tar -C /opt/xtables --strip-components=3 --exclude=./bin/aux/mo* './bin/aux/'
### END K3S XTABLES #####

### BEGIN RUNIT ###
# We need to build runit because there aren't any rpms for it in CentOS or BCI repositories.
FROM bci AS runit
ARG RUNIT_VER=2.3.1
# Install build dependencies and security updates.
# RUN yum install -y rpm-build yum-utils make && \
#     yum install -y wget glibc-static gcc    && \
#     yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical
RUN zypper update -y && \
    zypper install -y  \ 
    make gcc wget glibc-devel glibc-devel-static
# runit is not available in bci or CentOS repos so build it.
ADD http://smarden.org/runit/runit-${RUNIT_VER}.tar.gz /tmp/runit.tar.gz
WORKDIR /opt/local
RUN tar xzf /tmp/runit.tar.gz --strip-components=2 -C .
RUN ./package/install
### END RUNIT #####

FROM bci AS runtime_packages

# Install required packages into the minimal runtime filesystem.
COPY --from=runtime_rootfs / /rootfs
COPY --from=bci /etc/zypp/repos.d/ /rootfs/etc/zypp/repos.d/
COPY packages.txt /tmp/
RUN zypper --gpg-auto-import-keys --root /rootfs install -y $(sed 's/#.*//' /tmp/packages.txt)
RUN zypper --gpg-auto-import-keys --root /rootfs update -y && \
    rm -rf /rootfs/etc/zypp /rootfs/var/cache/zypp

# Kludge for files required by the ipset binary
COPY --from=bci /usr/etc/protocols /rootfs/etc/protocols
COPY --from=bci /usr/etc/services /rootfs/etc/services

### BEGIN CALICO WHISKER ###
# Copy only the release UI payload from the immutable upstream image; the final
# runtime is assembled from supported BCI packages rather than inheriting UBI.
FROM quay.io/calico/whisker@${CALICO_WHISKER_SOURCE_DIGEST} AS calico_whisker_source

FROM bci AS calico_whisker_artifacts
COPY --from=calico_whisker_source /usr/share/nginx/html/ /usr/share/nginx/html/
COPY --from=calico_whisker_source /etc/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=calico_whisker_source /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
COPY --from=calico_whisker_source /usr/bin/nginx-start.sh /usr/bin/nginx-start.sh
COPY --from=calico_whisker_source /licenses/LICENSE /licenses/LICENSE
RUN sed -i \
        -e 's!/var/run/nginx.pid!/tmp/nginx.pid!g' \
        -e '/^user  nginx;$/d' \
        /etc/nginx/nginx.conf && \
    sed -i '/^sed -i .*nginx.conf$/d' /usr/bin/nginx-start.sh && \
    chmod 0755 /usr/bin/nginx-start.sh

FROM bci AS calico_whisker_runtime_packages
COPY --from=runtime_rootfs / /rootfs
COPY --from=bci /etc/zypp/repos.d/ /rootfs/etc/zypp/repos.d/
RUN zypper --gpg-auto-import-keys --root /rootfs install -y nginx && \
    zypper --gpg-auto-import-keys --root /rootfs update -y && \
    rm -rf /rootfs/etc/zypp /rootfs/var/cache/zypp

FROM runtime_rootfs AS calico-whisker-image
ARG TAG
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
LABEL org.opencontainers.image.source="https://github.com/projectcalico/calico"
LABEL org.opencontainers.image.title="Calico Whisker"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.version="${TAG}"
COPY --from=calico_whisker_runtime_packages /rootfs/ /
COPY --from=calico_whisker_artifacts /usr/share/nginx/html/ /usr/share/nginx/html/
COPY --from=calico_whisker_artifacts /etc/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=calico_whisker_artifacts /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
COPY --from=calico_whisker_artifacts /usr/bin/nginx-start.sh /usr/bin/nginx-start.sh
COPY --from=calico_whisker_artifacts /licenses/LICENSE /licenses/LICENSE
RUN mkdir -p /etc/config /var/cache/nginx /var/lib/nginx/tmp /var/log/nginx && \
    chown 10001:10001 /etc/config /var/cache/nginx /var/lib/nginx /var/log/nginx
USER 10001:10001
EXPOSE 8081
ENTRYPOINT ["/usr/bin/nginx-start.sh"]
### END CALICO WHISKER ###

### BEGIN CALICO ENVOY ###
FROM builder AS calico_envoy_gateway_artifacts
ARG TARGETARCH
ARG GOEXPERIMENT
ENV GOEXPERIMENT=${GOEXPERIMENT}
WORKDIR $GOPATH/src/github.com/projectcalico/calico/third_party/envoy-gateway
RUN make init-source
COPY go-mod-envoy-overrides ./go-mod-envoy-overrides
WORKDIR $GOPATH/src/github.com/projectcalico/calico/third_party/envoy-gateway/envoy-gateway
RUN go-mod-overrides.sh ../go-mod-envoy-overrides
RUN go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/envoy-gateway ./cmd/envoy-gateway
RUN go-assert-static.sh /usr/local/bin/envoy-gateway
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
    go-assert-boring.sh /usr/local/bin/envoy-gateway; \
    fi
# BoringCrypto verification requires Go symbol data, so only strip afterward.
RUN llvm-strip /usr/local/bin/envoy-gateway
RUN mkdir -p /var/lib/eg

FROM builder AS calico_envoy_ratelimit_artifacts
ARG TARGETARCH
ARG GOEXPERIMENT
ENV GOEXPERIMENT=${GOEXPERIMENT}
WORKDIR $GOPATH/src/github.com/projectcalico/calico/third_party/envoy-ratelimit
RUN make init-source
COPY go-mod-envoy-overrides ./go-mod-envoy-overrides
WORKDIR $GOPATH/src/github.com/projectcalico/calico/third_party/envoy-ratelimit/envoy-ratelimit
RUN go-mod-overrides.sh ../go-mod-envoy-overrides
RUN go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/ratelimit ./src/service_cmd
RUN go-assert-static.sh /usr/local/bin/ratelimit
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
    go-assert-boring.sh /usr/local/bin/ratelimit; \
    fi
# BoringCrypto verification requires Go symbol data, so only strip afterward.
RUN llvm-strip /usr/local/bin/ratelimit

FROM ${BCI_NANO_IMAGE} AS calico-envoy-gateway-image
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
LABEL org.opencontainers.image.source="https://github.com/projectcalico/calico"
LABEL org.opencontainers.image.title="Calico Envoy Gateway"
LABEL org.opencontainers.image.licenses="Apache-2.0"
COPY --from=calico_envoy_gateway_artifacts /usr/local/bin/envoy-gateway /usr/local/bin/envoy-gateway
COPY --chown=65532:65532 --from=calico_envoy_gateway_artifacts /var/lib/eg /var/lib/eg
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/envoy-gateway"]

FROM ${ENVOYBINARY_IMAGE} AS calico_envoy_proxy_artifacts

FROM runtime_rootfs AS calico-envoy-proxy-image
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
LABEL org.opencontainers.image.source="https://github.com/projectcalico/calico"
LABEL org.opencontainers.image.title="Calico Envoy Proxy"
LABEL org.opencontainers.image.licenses="Apache-2.0"
COPY --from=calico_envoy_proxy_artifacts /etc/envoy/envoy.yaml /etc/envoy/envoy.yaml
COPY --chmod=755 --from=calico_envoy_proxy_artifacts /usr/local/bin/envoy /usr/local/bin/envoy
EXPOSE 10000
ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]

FROM ${BCI_NANO_IMAGE} AS calico-envoy-ratelimit-image
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
LABEL org.opencontainers.image.source="https://github.com/projectcalico/calico"
LABEL org.opencontainers.image.title="Calico Envoy Ratelimit"
LABEL org.opencontainers.image.licenses="Apache-2.0"
COPY --from=calico_envoy_ratelimit_artifacts /usr/local/bin/ratelimit /bin/ratelimit
ENTRYPOINT ["/bin/ratelimit"]
### END CALICO ENVOY ###

### BEGIN CONSOLIDATED CALICO ###
# The v3.33 release combines the Go components behind `calico component <name>`.
# Combined components: apiserver, cni, confd, csi, dikastes, felix, flexvol,
# goldmane, guardian, key-cert-provisioner, kube-controllers, node, typha,
# webhooks, and whisker-backend.
FROM builder AS calico_combined
ARG TARGETARCH
ARG TAG
ARG GOEXPERIMENT
ENV GOEXPERIMENT=${GOEXPERIMENT}
WORKDIR $GOPATH/src/github.com/projectcalico/calico
ENV CGO_CFLAGS="-I/go/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf/src -I/go/src/github.com/projectcalico/calico/felix/bpf-gpl"
ENV CGO_LDFLAGS="-L/go/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf/src -lbpf -lelf -lz -lzstd"
RUN make -C felix/bpf-gpl/libbpf/src BUILD_STATIC_ONLY=1 && \
    go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/calico ./cmd/calico
RUN go-assert-static.sh /usr/local/bin/calico
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
    go-assert-boring.sh /usr/local/bin/calico; \
    fi

FROM builder AS csi_node_driver_registrar
# Calico keeps the registrar standalone and bundles it into the consolidated image:
# https://github.com/projectcalico/calico/blob/v3.33.0/pod2daemon/Makefile
RUN git clone --depth=1 https://github.com/kubernetes-csi/node-driver-registrar.git \
    $GOPATH/src/github.com/kubernetes-csi/node-driver-registrar && \
    cd $GOPATH/src/github.com/kubernetes-csi/node-driver-registrar && \
    REGISTRAR_VERSION="$(sed -n 's/^UPSTREAM_REGISTRAR_TAG[[:space:]]*[^=]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' $GOPATH/src/github.com/projectcalico/calico/pod2daemon/Makefile)" && \
    test -n "${REGISTRAR_VERSION}" && \
    git fetch --depth=1 origin "${REGISTRAR_VERSION}" && \
    git checkout "${REGISTRAR_VERSION}" && \
    rm -rf vendor && \
    CGO_ENABLED=0 go build -buildvcs=false -trimpath \
    -o /usr/local/bin/csi-node-driver-registrar cmd/csi-node-driver-registrar/*.go
RUN go-assert-static.sh /usr/local/bin/csi-node-driver-registrar

FROM runtime_rootfs AS calico-image
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
COPY --from=calico_combined /go/src/github.com/projectcalico/calico/LICENSE.md /licenses/LICENSE
COPY --from=calico_combined /usr/local/bin/calico /usr/bin/calico
COPY --from=csi_node_driver_registrar /usr/local/bin/csi-node-driver-registrar /usr/bin/csi-node-driver-registrar
COPY --from=calico_combined /go/src/github.com/projectcalico/calico/docker/calico/typha.cfg /etc/calico/typha.cfg
RUN ln -s calico /usr/bin/calicoctl && \
    ln -s calico /usr/bin/calico-ipam
USER 10001:10001
ENTRYPOINT ["/usr/bin/calico"]

# Calico BPF sources require the glibc headers and LLVM toolchain provided by the upstream release's go-build image.
FROM ${CALICO_GO_BUILD_IMAGE} AS calico_bpf_artifacts
ARG TARGETARCH
COPY --from=builder /go/src/github.com/projectcalico/calico /go/src/github.com/projectcalico/calico
WORKDIR /go/src/github.com/projectcalico/calico
RUN make -C felix/bpf-gpl ARCH=${TARGETARCH} all && \
    make -C felix/bpf-apache ARCH=${TARGETARCH} all && \
    mkdir -p /opt/calico/included-source && \
    tar -C felix -cJf /opt/calico/included-source/felix-ebpf-gpl.tar.xz bpf-gpl

FROM builder AS calico_node_artifacts
ARG TARGETARCH
ARG TAG
ARG GOEXPERIMENT
ENV GOEXPERIMENT=${GOEXPERIMENT}
WORKDIR $GOPATH/src/github.com/projectcalico/calico
ENV CGO_ENABLED=1
ENV CGO_CFLAGS="-I/go/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf/src -I/go/src/github.com/projectcalico/calico/felix/bpf-gpl"
ENV CGO_LDFLAGS="-L/go/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf/src -lbpf -lelf -lz -lzstd"
RUN make -C felix/bpf-gpl/libbpf/src BUILD_STATIC_ONLY=1
RUN go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/calico ./cmd/calico && \
    go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/mountns ./node/cmd/mountns
RUN go-assert-static.sh /usr/local/bin/calico /usr/local/bin/mountns
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
    go-assert-boring.sh /usr/local/bin/calico; \
    fi

FROM calico/bird:${BIRD_VERSION}-${TARGETARCH} AS calico_node_bird
FROM ${BPFTOOL_IMAGE} AS calico_node_bpftool

FROM runtime_rootfs AS calico-node-image
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
ENV SVDIR=/etc/service/enabled
ENV PATH=$PATH:/opt/cni/bin
COPY --from=runtime_packages /rootfs/ /
COPY --from=calico_node_artifacts /go/src/github.com/projectcalico/calico/LICENSE.md /licenses/LICENSE
COPY --from=calico_node_artifacts /go/src/github.com/projectcalico/calico/node/filesystem/etc/ /etc/
COPY --from=calico_node_artifacts /go/src/github.com/projectcalico/calico/node/filesystem/sbin/ /usr/sbin/
COPY --from=calico_node_artifacts /usr/local/bin/calico /usr/bin/calico
COPY --from=calico_node_artifacts /usr/local/bin/mountns /bin/mountns
COPY --from=calico_bpf_artifacts /go/src/github.com/projectcalico/calico/felix/bpf-gpl/bin/ /usr/lib/calico/bpf/
COPY --from=calico_bpf_artifacts /go/src/github.com/projectcalico/calico/felix/bpf-apache/bin/ /usr/lib/calico/bpf/
COPY --from=calico_bpf_artifacts /opt/calico/included-source/ /included-source/
COPY --from=calico_node_bird /bird /bin/bird
COPY --from=calico_node_bird /bird6 /bin/bird6
COPY --from=calico_node_bird /birdcl /bin/birdcl
COPY --from=calico_node_bird /birdcl6 /bin/birdcl6
COPY --from=calico_node_bpftool /bpftool /bin/bpftool
COPY --from=runit /opt/local/command/ /usr/sbin/
COPY --from=k3s_xtables /opt/xtables/ /usr/sbin/
COPY --from=cni /opt/cni/ /opt/cni/
# Preserve the legacy install-cni entry point while v3.33+ consolidates its implementation in calico component cni install.
RUN test -x /opt/cni/bin/loopback && \
    test -x /opt/cni/bin/bandwidth && \
    printf '%s\n' '#!/bin/sh' 'exec /usr/bin/calico component cni install "$@"' > /install-cni && \
    chmod 0755 /install-cni
CMD ["start_runit"]
### END CONSOLIDATED CALICO ###

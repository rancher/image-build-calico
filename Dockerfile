ARG BCI_BUILD_IMAGE=registry.suse.com/bci/bci-base:16.0
ARG BCI_RUNTIME_IMAGE=registry.suse.com/bci/bci-minimal:16.0-18.11@sha256:1dc0f455c88f49a50b036cb2217a0562fce5e82d3e6a3e9e2523cf5a5dc15856
ARG GO_IMAGE=rancher/hardened-build-base:v1.27.1b1
ARG CNI_IMAGE_VERSION=v1.9.1-build20260903
ARG CNI_IMAGE=rancher/hardened-cni-plugins:${CNI_IMAGE_VERSION}
ARG GOEXPERIMENT=boringcrypto
# These are all tracked in upstreams metadata.mk file. UpdateCLI will automatically update these values based on the selected Calico TAG.
# Upstream derives this tag in metadata.mk as $(GO_VERSION)-llvm$(LLVM_VERSION)-k8s$(K8S_VERSION:v%=%).
ARG CALICO_GO_BUILD_IMAGE=calico/go-build:1.27.1-llvm21.1.8-k8s1.37.0
ARG BIRD_VERSION=v0.3.3-211-g9111ec3c
ARG BPFTOOL_IMAGE=calico/bpftool:v7.5.0
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

### BEGIN CONSOLIDATED CALICO ###
# The v3.33 release combines the Go components behind `calico component <name>`.
# Combined components: apiserver, cni, confd, csi, dikastes, felix, flexvol,
# goldmane, guardian, key-cert-provisioner, kube-controllers, node, typha,
# webhooks, and whisker-backend.
FROM builder AS calico_combined
ARG TARGETARCH
ARG TAG
ARG GOEXPERIMENT
ARG NODE_DRIVER_REGISTRAR_VERSION=2d18e12bc5077c36cbd564be7eab9ea94c0c85fb
ENV GOEXPERIMENT=${GOEXPERIMENT}
WORKDIR $GOPATH/src/github.com/projectcalico/calico
ENV CGO_CFLAGS="-I/go/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf/src -I/go/src/github.com/projectcalico/calico/felix/bpf-gpl"
ENV CGO_LDFLAGS="-L/go/src/github.com/projectcalico/calico/felix/bpf-gpl/libbpf/src -lbpf -lelf -lz -lzstd"
RUN make -C felix/bpf-gpl/libbpf/src BUILD_STATIC_ONLY=1 && \
    go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/calico ./cmd/calico
RUN git clone --depth=1 https://github.com/kubernetes-csi/node-driver-registrar.git \
    $GOPATH/src/github.com/kubernetes-csi/node-driver-registrar && \
    cd $GOPATH/src/github.com/kubernetes-csi/node-driver-registrar && \
    git fetch --depth=1 origin ${NODE_DRIVER_REGISTRAR_VERSION} && \
    git checkout ${NODE_DRIVER_REGISTRAR_VERSION} && \
    go-build-static.sh -buildvcs=false -trimpath \
    -o /usr/local/bin/csi-node-driver-registrar ./cmd/csi-node-driver-registrar
RUN go-assert-static.sh /usr/local/bin/calico /usr/local/bin/csi-node-driver-registrar
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
    go-assert-boring.sh /usr/local/bin/calico /usr/local/bin/csi-node-driver-registrar; \
    fi

FROM runtime_rootfs AS calico-image
LABEL org.opencontainers.image.url="https://github.com/rancher/image-build-calico"
COPY --from=calico_combined /go/src/github.com/projectcalico/calico/LICENSE.md /licenses/LICENSE
COPY --from=calico_combined /usr/local/bin/calico /usr/bin/calico
COPY --from=calico_combined /usr/local/bin/csi-node-driver-registrar /usr/bin/csi-node-driver-registrar
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

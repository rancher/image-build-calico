ARG ARCH=${TARGETARCH}
ARG BCI_IMAGE=registry.suse.com/bci/bci-base
ARG GO_IMAGE=rancher/hardened-build-base:v1.23.4b1
ARG CNI_IMAGE_VERSION=v1.6.2-build20250124
ARG CNI_IMAGE=rancher/hardened-cni-plugins:${CNI_IMAGE_VERSION}
ARG GOEXPERIMENT=boringcrypto

FROM ${BCI_IMAGE} AS bci
FROM ${CNI_IMAGE} AS cni
FROM ${GO_IMAGE} AS builder
# setup required packages
ARG TAG=v3.29.1
RUN set -x && \
    apk --no-cache add \
    bash \
    curl \
    file \
    gcc \
    git \
    linux-headers \
    make \
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

### BEGIN K3S XTABLES ###
FROM builder AS k3s_xtables
ARG ARCH
ARG K3S_ROOT_VERSION=v0.14.1
ADD https://github.com/rancher/k3s-root/releases/download/${K3S_ROOT_VERSION}/k3s-root-xtables-${ARCH}.tar /opt/xtables/k3s-root-xtables.tar
RUN tar xvf /opt/xtables/k3s-root-xtables.tar -C /opt/xtables
### END K3S XTABLES #####

FROM calico/bird:v0.3.3-184-g202a2186-${ARCH} AS calico_bird

### BEGIN CALICOCTL ###
FROM builder AS calico_ctl
ARG ARCH
ARG TAG=v3.29.1
ARG GOEXPERIMENT
WORKDIR $GOPATH/src/github.com/projectcalico/calico/calicoctl
RUN GIT_COMMIT=$(git rev-parse --short HEAD) \
    GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/calico/calicoctl/calicoctl/commands.GitCommit=${GIT_COMMIT} \
    -X github.com/projectcalico/calico/calicoctl/calicoctl/commands.VERSION=${TAG} \
    " go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calicoctl ./calicoctl/
RUN go-assert-static.sh bin/*
RUN if [ "${ARCH}" = "amd64" ]; then go-assert-boring.sh bin/*; fi
RUN install -s bin/* /usr/local/bin
RUN calicoctl --version
### END CALICOCTL #####


### BEGIN CALICO CNI ###
FROM builder AS calico_cni
ARG ARCH
ARG TAG=v3.29.1
ARG GOEXPERIMENT
WORKDIR $GOPATH/src/github.com/projectcalico/calico/cni-plugin
COPY dualStack-changes.patch .
# Apply the patch only in versions v3.20 and v3.21. It is already part of v3.22
RUN if [[ "${TAG}" =~ "v3.20" || "${TAG}" =~ "v3.21" ]]; then patch -p1 < dualStack-changes.patch; fi
ENV GO_LDFLAGS="-linkmode=external -X main.VERSION=${TAG}"
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico ./cmd/calico
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico-ipam ./cmd/calico
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/install ./cmd/install
RUN go-assert-static.sh bin/*
RUN if [ "${ARCH}" = "amd64" ]; then go-assert-boring.sh bin/*; fi
RUN mkdir -vp /opt/cni/bin
RUN install -s bin/* /opt/cni/bin/
### END CALICO CNI #####


### BEGIN CALICO NODE ###
### Can't use go-build-static.sh due to -Wl and --fatal-warnings flags ###
FROM builder AS calico_node
ARG ARCH
ARG TAG=v3.29.1
ARG GOEXPERIMENT
WORKDIR $GOPATH/src/github.com/projectcalico/calico/node
RUN go mod download
ENV CGO_LDFLAGS="-L/go/src/github.com/projectcalico/calico/felix/bpf-gpl/include/libbpf/src -lbpf -lelf -lz -lzstd"
ENV CGO_CFLAGS="-I/go/src/github.com/projectcalico/calico/felix//bpf-gpl/include/libbpf/src -I/go/src/github.com/projectcalico/calico/felix//bpf-gpl"
ENV CGO_ENABLED=1
RUN if [ "${ARCH}" = "amd64" ]; then make -j 16 -C ../felix/bpf-gpl/include/libbpf/src BUILD_STATIC_ONLY=1; fi
RUN if [ "${ARCH}" = "amd64" ]; then \
    go build -ldflags "-linkmode=external -X github.com/projectcalico/calico/node/pkg/lifecycle/startup.VERSION=${TAG} \
    -X github.com/projectcalico/calico/node/buildinfo.GitRevision=$(git rev-parse HEAD) \
    -X github.com/projectcalico/calico/node/buildinfo.GitVersion=$(git describe --tags --always) \
    -X github.com/projectcalico/calico/node/buildinfo.BuildDate=$(date -u +%FT%T%z) -extldflags \"-static\"" \
    -gcflags=-trimpath=${GOPATH}/src -o bin/calico-node ./cmd/calico-node; \
    fi
RUN if [ "${ARCH}" != "amd64" ]; then \  
    CGO_LDFLAGS="-lelf -lz -lzstd" && CGO_CFLAGS="" && go build -ldflags "-linkmode=external \
    -X github.com/projectcalico/calico/node/pkg/lifecycle/startup.VERSION=${TAG} \
    -X github.com/projectcalico/calico/node/buildinfo.GitRevision=$(git rev-parse HEAD) \
    -X github.com/projectcalico/calico/node/buildinfo.GitVersion=$(git describe --tags --always) \
    -X github.com/projectcalico/calico/node/buildinfo.BuildDate=$(date -u +%FT%T%z) -extldflags \"-static\"" \
    -gcflags=-trimpath=${GOPATH}/src -o bin/calico-node ./cmd/calico-node; \
    fi
RUN go-assert-static.sh bin/calico-node
RUN if [ "${ARCH}" = "amd64" ]; then go-assert-boring.sh bin/calico-node; fi
RUN install -s bin/calico-node /usr/local/bin
### END CALICO NODE #####


### BEGIN CALICO POD2DAEMON ###
FROM builder AS calico_pod2daemon
ARG GOEXPERIMENT
WORKDIR $GOPATH/src/github.com/projectcalico/calico/pod2daemon
ENV GO_LDFLAGS="-linkmode=external"
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/flexvoldriver ./flexvol
RUN go-assert-static.sh bin/*
RUN install -m 0755 flexvol/docker-image/flexvol.sh /usr/local/bin/
RUN install -D -s bin/flexvoldriver /usr/local/bin/flexvol/flexvoldriver
### END CALICO POD2DAEMON #####

### BEGIN CALICO KUBE-CONTROLLERS ###
FROM builder AS calico_kubecontrollers
ARG TAG=v3.29.1
ARG GOEXPERIMENT
WORKDIR $GOPATH/src/github.com/projectcalico/calico/kube-controllers
RUN GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/calico/kube-controllers/main.VERSION=${TAG}" \
    go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/kube-controllers ./cmd/kube-controllers/
RUN GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/calico/kube-controllers/main.VERSION=${TAG}" \
    go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/check-status ./cmd/check-status/
RUN go-assert-static.sh bin/*
RUN install -D -s bin/kube-controllers /usr/local/bin/
RUN install -D -s bin/check-status /usr/local/bin/
### END CALICO KUBE-CONTROLLERS #####

### BEGIN RUNIT ###
# We need to build runit because there aren't any rpms for it in CentOS or BCI repositories.
FROM ${BCI_IMAGE} AS runit
ARG RUNIT_VER=2.1.2
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


# gather all of the disparate calico bits into a rootfs overlay
FROM scratch AS calico_rootfs_overlay_amd64
COPY --from=calico_node /go/src/github.com/projectcalico/calico/node/filesystem/etc/       /etc/
COPY --from=calico_node /go/src/github.com/projectcalico/calico/licenses/  /licenses/
COPY --from=calico_node /go/src/github.com/projectcalico/calico/node/filesystem/sbin/      /usr/sbin/
COPY --from=calico_node /usr/local/bin/      	     /usr/bin/
COPY --from=calico_ctl /usr/local/bin/calicoctl      /calicoctl
COPY --from=calico_bird /bird*                       /usr/bin/
COPY --from=calico/bpftool:v5.3-amd64 /bpftool       /usr/sbin/
COPY --from=calico_pod2daemon /usr/local/bin/        /usr/local/bin/
COPY --from=calico_kubecontrollers /usr/local/bin/   /usr/bin/
COPY --from=calico_cni /opt/cni/                     /opt/cni/
COPY --from=cni	/opt/cni/                            /opt/cni/
COPY --from=k3s_xtables /opt/xtables/bin/            /usr/sbin/
COPY --from=runit /opt/local/command/                /usr/sbin/

FROM scratch AS calico_rootfs_overlay_arm64
COPY --from=calico_node /go/src/github.com/projectcalico/calico/node/filesystem/etc/       /etc/
COPY --from=calico_node /go/src/github.com/projectcalico/calico/licenses/  /licenses/
COPY --from=calico_node /go/src/github.com/projectcalico/calico/node/filesystem/sbin/      /usr/sbin/
COPY --from=calico_node /usr/local/bin/      	     /usr/bin/
COPY --from=calico_ctl /usr/local/bin/calicoctl      /calicoctl
COPY --from=calico_bird /bird*                       /usr/bin/
COPY --from=calico/bpftool:v5.3-arm64 /bpftool       /usr/sbin/
COPY --from=calico_pod2daemon /usr/local/bin/        /usr/local/bin/
COPY --from=calico_kubecontrollers /usr/local/bin/   /usr/bin/
COPY --from=calico_cni /opt/cni/                     /opt/cni/
COPY --from=cni	/opt/cni/                            /opt/cni/
COPY --from=k3s_xtables /opt/xtables/bin/            /usr/sbin/
COPY --from=runit /opt/local/command/                /usr/sbin/

FROM scratch AS calico_rootfs_overlay_s390x
COPY --from=calico_node /go/src/github.com/projectcalico/calico/node/filesystem/etc/       /etc/
COPY --from=calico_node /go/src/github.com/projectcalico/calico/licenses/  /licenses/
COPY --from=calico_node /go/src/github.com/projectcalico/calico/node/filesystem/sbin/      /usr/sbin/
COPY --from=calico_node /usr/local/bin/      	     /usr/bin/
COPY --from=calico_ctl /usr/local/bin/calicoctl      /calicoctl
COPY --from=calico_bird /bird*                       /usr/bin/
COPY --from=calico_pod2daemon /usr/local/bin/        /usr/local/bin/
COPY --from=calico_kubecontrollers /usr/local/bin/   /usr/bin/
COPY --from=calico_cni /opt/cni/                     /opt/cni/
COPY --from=cni	/opt/cni/                            /opt/cni/
COPY --from=k3s_xtables /opt/xtables/bin/            /usr/sbin/
COPY --from=runit /opt/local/command/                /usr/sbin/

FROM calico_rootfs_overlay_${ARCH} AS calico_rootfs_overlay

FROM bci
RUN zypper update -y && \
    zypper install -y  \
    hostname \
    libpcap1 \
    libmnl0 \
    libnetfilter_conntrack3 \
    libnetfilter_cthelper0 \
    libnetfilter_cttimeout1   \
    libnetfilter_queue1 \
    ipset \
    kmod \
    iputils \
    iproute2 \
    procps \
    net-tools \
    conntrack-tools \
    which  && \
    rm -rf /var/cache/zypp/packages
COPY --from=calico_rootfs_overlay / /
ENV PATH=$PATH:/opt/cni/bin
RUN set -x && \
    test -e /opt/cni/bin/install && \
    ln -vs /opt/cni/bin/install /install-cni

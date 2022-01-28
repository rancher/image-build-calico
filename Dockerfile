ARG ARCH="amd64"
ARG TAG="v3.21.4"
ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.17.3b7
ARG CNI_IMAGE=rancher/hardened-cni-plugins:v0.9.1-build20211119
ARG GO_BORING=goboring/golang:1.16.7b7

FROM ${UBI_IMAGE} as ubi
FROM ${CNI_IMAGE} as cni
FROM ${GO_IMAGE} as builder
# setup required packages
RUN set -x \
 && apk --no-cache add \
    bash \
    curl \
    file \
    gcc \
    git \
    linux-headers \
    make \
    patch

# Image for projectcalico/node. Because of libbpf-dev and libelf-dev dependencies we can't use Alpine. Not needed in s390x
FROM ${GO_BORING} AS builder-amd64
FROM builder AS builder-s390x
FROM builder-${ARCH} AS calico-node-builder
ARG ARCH
RUN if [ "${ARCH}" = "amd64" ]; then apt -y update && apt -y upgrade && apt install -y file libbpf-dev gcc build-essential libelf-dev; fi
COPY --from=builder /usr/local/go/bin/go-assert-boring.sh /usr/local/go/bin/go-assert-static.sh /usr/local/go/bin/go-build-static.sh /usr/local/go/bin/

### BEGIN K3S XTABLES ###
FROM builder AS k3s_xtables
ARG ARCH
ARG K3S_ROOT_VERSION=v0.10.1
ADD https://github.com/rancher/k3s-root/releases/download/${K3S_ROOT_VERSION}/k3s-root-xtables-${ARCH}.tar /opt/xtables/k3s-root-xtables.tar
RUN tar xvf /opt/xtables/k3s-root-xtables.tar -C /opt/xtables
### END K3S XTABLES #####

FROM calico/bird:v0.3.3-184-g202a2186-${ARCH} AS calico_bird

### BEGIN CALICOCTL ###
FROM builder AS calico_ctl
ARG ARCH
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/calicoctl.git $GOPATH/src/github.com/projectcalico/calicoctl
WORKDIR $GOPATH/src/github.com/projectcalico/calicoctl
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
RUN GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/calicoctl/calicoctl/commands.VERSION=${TAG} \
    -X github.com/projectcalico/calicoctl/calicoctl/commands.GIT_REVISION=$(git rev-parse --short HEAD) \
    " go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calicoctl ./calicoctl/calicoctl.go
RUN go-assert-static.sh bin/*
RUN if [ "${ARCH}" = "amd64" ]; then go-assert-boring.sh bin/*; fi
RUN install -s bin/* /usr/local/bin
RUN calicoctl --version
### END CALICOCTL #####


### BEGIN CALICO CNI ###
FROM builder AS calico_cni
ARG ARCH
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/cni-plugin.git $GOPATH/src/github.com/projectcalico/cni-plugin
WORKDIR $GOPATH/src/github.com/projectcalico/cni-plugin
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
COPY dualStack-changes.patch .
# Apply the patch only in versions v3.20 and v3.21. It is already part of v3.22
RUN if [[ "${TAG}" =~ "v3.20" || "${TAG}" =~ "v3.21" ]]; then git apply dualStack-changes.patch; fi
ENV GO_LDFLAGS="-linkmode=external -X main.VERSION=${TAG}"
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico ./cmd/calico
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico-ipam ./cmd/calico
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/install ./cmd/calico
RUN go-assert-static.sh bin/*
RUN if [ "${ARCH}" = "amd64" ]; then go-assert-boring.sh bin/*; fi
RUN mkdir -vp /opt/cni/bin
RUN install -s bin/* /opt/cni/bin/
### END CALICO CNI #####


### BEGIN CALICO NODE ###
FROM calico-node-builder AS calico_node
ARG ARCH
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/node.git $GOPATH/src/github.com/projectcalico/node
WORKDIR $GOPATH/src/github.com/projectcalico/node
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
RUN mkdir -p bin/third-party && go mod download && cp -r `go list -mod=mod -m -f "{{.Dir}}" github.com/projectcalico/felix`/bpf-gpl/include/libbpf bin/third-party && chmod -R +w bin/third-party
RUN if [ "${ARCH}" = "amd64" ]; then make -j 16 -C bin/third-party/libbpf/src BUILD_STATIC_ONLY=1; fi
RUN GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/node/pkg/startup.VERSION=${TAG} \
    -X github.com/projectcalico/node/buildinfo.GitRevision=$(git rev-parse HEAD) \
    -X github.com/projectcalico/node/buildinfo.GitVersion=$(git describe --tags --always) \
    -X github.com/projectcalico/node/buildinfo.BuildDate=$(date -u +%FT%T%z)" \
    CGO_LDFLAGS="-L/go/src/github.com/projectcalico/node/bin/third-party/libbpf/src -lbpf -lelf -lz" \
    CGO_CFLAGS="-I/go/src/github.com/projectcalico/node/bin/third-party/libbpf/src" \
    CGO_ENABLED=1 go build -ldflags "-linkmode=external -extldflags \"-static\"" -gcflags=-trimpath=${GOPATH}/src -o bin/calico-node ./cmd/calico-node
RUN go-assert-static.sh bin/calico-node
RUN go-assert-boring.sh bin/calico-node
RUN install -s bin/calico-node /usr/local/bin
### END CALICO NODE #####


### BEGIN CALICO POD2DAEMON ###
FROM builder AS calico_pod2daemon
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/pod2daemon.git $GOPATH/src/github.com/projectcalico/pod2daemon
WORKDIR $GOPATH/src/github.com/projectcalico/pod2daemon
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
ENV GO_LDFLAGS="-linkmode=external"
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/flexvoldriver ./flexvol
RUN go-assert-static.sh bin/*
RUN install -m 0755 flexvol/docker/flexvol.sh /usr/local/bin/
RUN install -D -s bin/flexvoldriver /usr/local/bin/flexvol/flexvoldriver
### END CALICO POD2DAEMON #####


### BEGIN RUNIT ###
# We need to build runit because there aren't any rpms for it in CentOS or ubi repositories.
FROM centos:7 AS runit-amd64
FROM clefos:7 AS runit-s390x
FROM runit-${ARCH} AS runit
ARG RUNIT_VER=2.1.2
# Install build dependencies and security updates.
RUN yum install -y rpm-build yum-utils make && \
    yum install -y wget glibc-static gcc    && \
    yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical
# runit is not available in ubi or CentOS repos so build it.
ADD http://smarden.org/runit/runit-${RUNIT_VER}.tar.gz /tmp/runit.tar.gz
WORKDIR /opt/local
RUN tar xzf /tmp/runit.tar.gz --strip-components=2 -C .
RUN ./package/install
### END RUNIT #####


# gather all of the disparate calico bits into a rootfs overlay
FROM scratch AS calico_rootfs_overlay_amd64
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/etc/       /etc/
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/licenses/  /licenses/
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/sbin/      /usr/sbin/
COPY --from=calico_node /usr/local/bin/      	/usr/bin/
COPY --from=calico_ctl /usr/local/bin/calicoctl /calicoctl
COPY --from=calico_bird /bird*                  /usr/bin/
COPY --from=calico/bpftool:v5.3-amd64 /bpftool  /usr/sbin/
COPY --from=calico_pod2daemon /usr/local/bin/   /usr/local/bin/
COPY --from=calico_cni /opt/cni/                /opt/cni/
COPY --from=cni	/opt/cni/                       /opt/cni/
COPY --from=k3s_xtables /opt/xtables/bin/       /usr/sbin/
COPY --from=runit /opt/local/command/           /usr/sbin/

FROM scratch AS calico_rootfs_overlay_s390x
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/etc/       /etc/
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/licenses/  /licenses/
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/sbin/      /usr/sbin/
COPY --from=calico_node /usr/local/bin/      	/usr/bin/
COPY --from=calico_ctl /usr/local/bin/calicoctl /calicoctl
COPY --from=calico_bird /bird*                  /usr/bin/
COPY --from=calico_pod2daemon /usr/local/bin/   /usr/local/bin/
COPY --from=calico_cni /opt/cni/                /opt/cni/
COPY --from=cni	/opt/cni/                       /opt/cni/
COPY --from=k3s_xtables /opt/xtables/bin/       /usr/sbin/
COPY --from=runit /opt/local/command/           /usr/sbin/

FROM calico_rootfs_overlay_${ARCH} as calico_rootfs_overlay

FROM ubi
RUN microdnf update -y                         && \
    microdnf install hostname                     \
    libpcap libmnl libnetfilter_conntrack         \
    libnetfilter_cthelper libnetfilter_cttimeout  \
    libnetfilter_queue ipset kmod iputils iproute \
    procps net-tools conntrack-tools which     && \
    rm -rf /var/cache/yum
COPY --from=calico_rootfs_overlay / /
ENV PATH=$PATH:/opt/cni/bin
RUN set -x \
 && test -e /opt/cni/bin/install \
 && ln -vs /opt/cni/bin/install /install-cni \

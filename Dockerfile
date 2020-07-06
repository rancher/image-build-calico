ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=briandowns/rancher-build-base:v0.1.1
ARG RUNIT_VER=2.1.2
ARG BIRD_IMAGE=calico/bird:v0.3.3-160-g7df7218c-amd64

FROM ${UBI_IMAGE} as ubi

FROM ${GO_IMAGE} as builder
ARG TAG="" 
RUN apt update                                      && \ 
    apt upgrade -y                                  && \ 
    apt install -y apt-transport-https ca-certificates \
                   software-properties-common git      \
                   curl bash

RUN git clone --depth=1 https://github.com/projectcalico/calicoctl.git
RUN cd /go/calicoctl                                                                                                                                 && \
    git fetch --all --tags --prune                                                                                                                   && \
    git checkout tags/${TAG} -b ${TAG}                                                                                                               && \
    CGO_ENABLED=1 go build -v -o bin/calicoctl -ldflags "-X github.com/projectcalico/calicoctl/calicoctl/commands.VERSION=$(git rev-parse --short HEAD) \
    -X github.com/projectcalico/calicoctl/calicoctl/commands.GIT_REVISION=$(git rev-parse --short HEAD) -s -w" "./calicoctl/calicoctl.go"            && \
    cd /go

RUN git clone --depth=1 https://github.com/projectcalico/cni-plugin.git
RUN cd /go/cni-plugin                                                                                                             && \
    git fetch --all --tags --prune                                                                                                && \
    git checkout tags/${TAG} -b ${TAG}                                                                                            && \
    mkdir bin                                                                                                                     && \
    CGO_ENABLED=1 go build -v -o bin/calico -ldflags "-X main.VERSION=$(git rev-parse --short HEAD) -s -w" ./cmd/calico           && \
    CGO_ENABLED=1 go build -v -o bin/calico-ipam -ldflags "-X main.VERSION=$(git rev-parse --short HEAD) -s -w" ./cmd/calico-ipam && \
    make fetch-cni-bins                                                                                                           && \
    cd /go

RUN git clone --depth=1 https://github.com/projectcalico/node.git
RUN cd /go/node                                                                                                                                           && \
    git fetch --all --tags --prune                                                                                                                        && \
    git checkout tags/${TAG} -b ${TAG}                                                                                                                    && \
    mkdir -p dist/bin                                                                                                                                     && \
    CGO_ENABLED=1 go build -v -o dist/bin/calico-node -ldflags "-X github.com/projectcalico/node/pkg/startup.VERSION=$(git describe --tags --dirty --always) \
    -X github.com/projectcalico/node/buildinfo.GitVersion=$(git describe --tags --dirty --always)                                                            \
    -X github.com/projectcalico/node/buildinfo.BuildDate=$(date -u +'%FT%T%z')                                                                               \
    -X github.com/projectcalico/node/buildinfo.GitRevision=$(git rev-parse HEAD)" ./cmd/calico-node/main.go                                               && \
    cd /go

RUN git clone --depth=1 https://github.com/projectcalico/pod2daemon.git
RUN cd /go/pod2daemon                  && \
    git fetch --all --tags --prune     && \
    git checkout tags/${TAG} -b ${TAG} && \
    mkdir -p bin/flexvol-amd64         && \
    CGO_ENABLED=1 go build -v -o bin/flexvol-amd64 flexvol/flexvoldriver.go

FROM calico/bpftool:v5.3-amd64 as bpftool
FROM calico/felix:latest as felix

FROM ${BIRD_IMAGE} as bird

# Use this build stage to build runit.
# We need to build runit because there aren't any rpms for it in CentOS or ubi repositories.
FROM centos:7 as centos
ARG RUNIT_VER

# Install build dependencies and security updates.
RUN yum install -y rpm-build yum-utils make && \
    yum install -y wget glibc-static gcc    && \
    yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical

# runit is not available in ubi or CentOS repos so build it.
RUN wget -P /tmp http://smarden.org/runit/runit-${RUNIT_VER}.tar.gz && \
    gunzip /tmp/runit-${RUNIT_VER}.tar.gz                           && \
    tar -xpf /tmp/runit-${RUNIT_VER}.tar -C /tmp                    && \
    cd /tmp/admin/runit-${RUNIT_VER}/                               && \
    package/install

FROM ubi
RUN microdnf update -y                         && \
    microdnf install iptables hostname            \
    libpcap libmnl libnetfilter_conntrack         \ 
    libnetfilter_cthelper libnetfilter_cttimeout  \
    libnetfilter_queue ipset kmod iputils iproute \
    procps net-tools conntrack-tools which     && \
    rm -rf /var/cache/yum

ARG GIT_VERSION
ARG RUNIT_VER

# Copy in runit binaries
COPY --from=centos /tmp/admin/runit-${RUNIT_VER}/command/* /usr/local/bin/

# Copy our bird binaries in
COPY --from=bird /bird* /bin/

# Copy in the filesystem - this contains felix, calico-bgp-daemon, licenses, etc...
COPY --from=builder /go/node/filesystem/ /

# Add symlink to modprobe where iptables expects it to be.
# This has to come after copying over filesystem/, since that may overwrite /sbin depending on the base image.
RUN ln -s /usr/sbin/modprobe /sbin/modprobe

RUN mkdir -p /opt/cni
ENV PATH=$PATH:/opt/cni/bin

COPY --from=builder /go/calicoctl/bin/calicoctl /calicoctl

COPY --from=builder /go/cni-plugin/bin/calico /opt/cni/bin/calico
COPY --from=builder /go/cni-plugin/bin/calico-ipam /opt/cni/bin/calico-ipam
COPY --from=builder /go/cni-plugin/k8s-install/scripts/install-cni.sh /install-cni.sh
COPY --from=builder /go/cni-plugin/k8s-install/scripts/calico.conf.default /calico.conf.tmp
COPY --from=builder /go/cni-plugin/bin/amd64 /opt/cni/bin

COPY --from=builder /go/node/dist/bin /bin
COPY --from=bpftool /bpftool /bin
COPY --from=felix /usr/lib/calico /usr/lib/calico

COPY --from=builder /go/pod2daemon/flexvol/docker/flexvol.sh /usr/local/bin
COPY --from=builder /go/pod2daemon/bin/flexvol-amd64 /usr/local/bin/flexvol


ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=briandowns/rancher-build-base:v0.1.1
ARG ARCH=x86_64
ARG GIT_VERSION=unknown
ARG IPTABLES_VER=1.8.2-16
ARG RUNIT_VER=2.1.2
ARG BIRD_IMAGE=calico/bird:v0.3.3-160-g7df7218c-amd64

FROM ${UBI_IMAGE} as ubi

FROM ${GO_IMAGE} as builder
ARG TAG="" 
RUN apt update     && \ 
    apt upgrade -y && \ 
    apt install -y apt-transport-https ca-certificates \
                   software-properties-common git      \
                   curl bash

RUN git clone --depth=1 https://github.com/projectcalico/calicoctl.git
RUN cd /go/calicoctl                   && \
    git fetch --all --tags --prune     && \
    git checkout tags/${TAG} -b ${TAG} && \
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
RUN cd /go/node                                                                                                                                                 && \
    git fetch --all --tags --prune                                                                                                                              && \
    git checkout tags/${TAG} -b ${TAG}                                                                                                                          && \
    mkdir -p dist/bin                                                                                                                                           && \
    CGO_ENABLED=1 go build -v -o dist/bin/calico-node -ldflags "-X github.com/projectcalico/node/pkg/startup.VERSION=$(git describe --tags --dirty --always)       \
    -X github.com/projectcalico/node/buildinfo.GitVersion=$(git describe --tags --dirty --always)                                                                  \
    -X github.com/projectcalico/node/buildinfo.BuildDate=$(date -u +'%FT%T%z')                                                                                     \
    -X github.com/projectcalico/node/buildinfo.GitRevision=$(git rev-parse HEAD)" ./cmd/calico-node/main.go                                                     && \
    cd /go

RUN git clone --depth=1 https://github.com/projectcalico/pod2daemon.git
RUN cd /go/pod2daemon                  && \
    git fetch --all --tags --prune     && \
    git checkout tags/${TAG} -b ${TAG} && \
    mkdir -p bin/flexvol-amd64         && \
    CGO_ENABLED=1 go build -v -o bin/flexvol-amd64 flexvol/flexvoldriver.go

FROM calico/bpftool:v5.3-amd64 as bpftool
FROM ${BIRD_IMAGE} as bird

# Use this build stage to build iptables rpm and runit binaries.
# We need to rebuild the iptables rpm because the prepackaged rpm does not have legacy iptables binaries.
# We need to build runit because there aren't any rpms for it in CentOS or ubi repositories.
FROM centos:8 as centos

ARG ARCH
ARG IPTABLES_VER
ARG RUNIT_VER
ARG CENTOS_MIRROR_BASE_URL=http://vault.centos.org/8.1.1911
ARG LIBNFTNL_VER=1.1.1-4
ARG LIBNFTNL_SOURCERPM_URL=${CENTOS_MIRROR_BASE_URL}/BaseOS/Source/SPackages/libnftnl-${LIBNFTNL_VER}.el8.src.rpm
ARG IPTABLES_SOURCERPM_URL=${CENTOS_MIRROR_BASE_URL}/BaseOS/Source/SPackages/iptables-${IPTABLES_VER}.el8.src.rpm

# Install build dependencies and security updates.
RUN dnf install -y 'dnf-command(config-manager)' && \
    # Enable PowerTools repo for '-devel' packages
    dnf config-manager --set-enabled PowerTools  && \
    # Install required packages for building rpms. yum-utils is not required but it gives us yum-builddep to easily install build deps.
    yum install -y rpm-build yum-utils make      && \
    # Need these to build runit.
    yum install -y wget glibc-static gcc         && \
    # Ensure security updates are installed.
    yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical

# In order to rebuild the iptables RPM, we first need to rebuild the libnftnl RPM because building
# iptables requires libnftnl-devel but libnftnl-devel is not available on ubi or CentOS repos.
# (Note: it's not in RHEL8.1 either https://bugzilla.redhat.com/show_bug.cgi?id=1711361).
# Rebuilding libnftnl will give us libnftnl-devel too.
#RUN rpm -i ${LIBNFTNL_SOURCERPM_URL}                                                   && \
#    yum-builddep -y --spec /root/rpmbuild/SPECS/libnftnl.spec                          && \
#    rpmbuild -bb /root/rpmbuild/SPECS/libnftnl.spec                                    && \
    # Now install libnftnl and libnftnl-devel
#    rpm -Uv /root/rpmbuild/RPMS/${ARCH}/libnftnl-${LIBNFTNL_VER}.el8.${ARCH}.rpm       && \
#    rpm -Uv /root/rpmbuild/RPMS/${ARCH}/libnftnl-devel-${LIBNFTNL_VER}.el8.${ARCH}.rpm && \
    # Install source RPM for iptables and install its build dependencies.
#    rpm -i ${IPTABLES_SOURCERPM_URL}                                                   && \
#    yum-builddep -y --spec /root/rpmbuild/SPECS/iptables.spec

# Patch the iptables build spec so that we keep the legacy iptables binaries.
#RUN sed -i '/drop all legacy tools/,/sbindir.*legacy/d' /root/rpmbuild/SPECS/iptables.spec

# Patch the iptables build spec to drop the renaming of nft binaries. Instead of renaming binaries,
# we will use alternatives to set the canonical iptables binaries.
#RUN sed -i '/rename nft versions to standard name/,/^done/d' /root/rpmbuild/SPECS/iptables.spec

# Patch the iptables build spec so that legacy and nft iptables binaries are verified to be in the resulting rpm.
#RUN sed -i '/%files$/a \
#\%\{_sbindir\}\/xtables-legacy-multi \n\
#\%\{_sbindir\}\/ip6tables-legacy \n\
#\%\{_sbindir\}\/ip6tables-legacy-restore \n\
#\%\{_sbindir\}\/ip6tables-legacy-save \n\
#\%\{_sbindir\}\/iptables-legacy \n\
#\%\{_sbindir\}\/iptables-legacy-restore \n\
#\%\{_sbindir\}\/iptables-legacy-save \n\
#\%\{_sbindir\}\/ip6tables-nft\n\
#\%\{_sbindir\}\/ip6tables-nft-restore\n\
#\%\{_sbindir\}\/ip6tables-nft-save\n\
#\%\{_sbindir\}\/iptables-nft\n\
#\%\{_sbindir\}\/iptables-nft-restore\n\
#\%\{_sbindir\}\/iptables-nft-save\n\
#' /root/rpmbuild/SPECS/iptables.spec

# Finally rebuild iptables.
#RUN rpmbuild -bb /root/rpmbuild/SPECS/iptables.spec

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
#FROM registry.access.redhat.com/ubi8/ubi-minimal:8.1-407
ARG ARCH
ARG GIT_VERSION
#ARG IPTABLES_VER
ARG RUNIT_VER

# Required labels for certification
LABEL name="Calico node"                                                 \
      vendor="Project Calico"                                            \
      version=$GIT_VERSION                                               \
      release="1"                                                        \
      summary="Calico node handles networking and policy for Calico"     \
      description="Calico node handles networking and policy for Calico" \
      maintainer="laurence@tigera.io"

# Copy in runit binaries
COPY --from=centos /tmp/admin/runit-${RUNIT_VER}/command/* /usr/local/bin/

# Copy in our rpms
#COPY --from=centos /root/rpmbuild/RPMS/${ARCH}/* /tmp/rpms/

# Install the necessary packages, making sure that we're using only CentOS repos.
# Since the ubi repos do not contain all the packages we need (they're missing conntrack-tools),
# we're using CentOS repos for all our packages. Using packages from a single source (CentOS) makes
# it less likely we'll run into package dependency version mismatches.
#COPY --from=builder /go/node/centos.repo /etc/yum.repos.d/
#RUN rm /etc/yum.repos.d/ubi.repo                                                   && \
#    microdnf install                                                                  \
#    hostname                                                                          \
    # Needed for iptables
#    libpcap libmnl libnfnetlink libnftnl libnetfilter_conntrack                       \
#    ipset                                                                             \
#    iputils                                                                           \
    # Need arp
#    net-tools                                                                         \
    # Need kmod to ensure ip6tables-save works correctly
#    kmod                                                                              \
    # Also needed (provides utilities for browsing procfs like ps)
#    procps                                                                            \
#    iproute                                                                           \
#    iproute-tc                                                                        \
    # Needed for conntrack
#    libnetfilter_cthelper libnetfilter_cttimeout libnetfilter_queue                   \
#    conntrack-tools                                                                   \
    # Needed for runit startup script
#    which                                                                          && \
#    microdnf clean all                                                             
    # Install iptables via rpms. The libs must be force installed because the iptables source RPM has the release
    # version '9.el8_0.1' while the existing iptables-libs (pulled in by the iputils package) has version '9.el8.1'.
    #rpm --force -i /tmp/rpms/iptables-libs-${IPTABLES_VER}.el8.${ARCH}.rpm         && \
    #rpm -i /tmp/rpms/iptables-${IPTABLES_VER}.el8.${ARCH}.rpm                      && \
    # Set alternatives
    #alternatives --install /usr/sbin/iptables iptables /usr/sbin/iptables-legacy 1 && \
    #alternatives --install /usr/sbin/ip6tables ip6tables /usr/sbin/ip6tables-legacy 1

# Add mitigation for https://access.redhat.com/security/cve/CVE-2019-15718
# This can be removed once we update to ubi:8.1
#RUN systemctl disable systemd-resolved

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

COPY --from=builder /go/pod2daemon/flexvol/docker/flexvol.sh /usr/local/bin
COPY --from=builder /go/pod2daemon/bin/flexvol-amd64 /usr/local/bin/flexvol


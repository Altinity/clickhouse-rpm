#!/bin/bash
#
# Yandex ClickHouse DBMS build script for RHEL based distributions
#
# Important notes:
#  - build requires ~35 GB of disk space
#  - each build thread requires 2 GB of RAM - for example, if you
#    have dual-core CPU with 4 threads you need 8 GB of RAM
#  - build user needs to have sudo priviledges, preferrably with NOPASSWD
#
# Tested on:
#  - CentOS 6: 6.8, 6.9
#  - CentOS 7: 7.2, 7.3, 7.4
#  - RHEL 7: 7.4
#  - Fedora: 25, 26
#
# Copyright (C) 2016 Red Soft LLC
# Copyright (C) 2017 Altinity Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Git version of ClickHouse that we package
CH_VERSION="${CH_VERSION:-1.1.54310}"

# Git tag marker (stable/testing)
CH_TAG="${CH_TAG:-stable}"
#CH_TAG="${CH_TAG:-testing}"

# Hostname of the server used to publish packages
SSH_REPO_SERVER="${SSH_REPO_SERVER:-10.81.1.162}"

# SSH username used to publish packages
SSH_REPO_USER="${SSH_REPO_USER:-clickhouse}"

# Root directory for repositories on the server used to publish packages
SSH_REPO_ROOT="${SSH_REPO_ROOT:-/var/www/html/repos/clickhouse}"

# Current work dir
CWD_DIR=$(pwd)

# Source files dir
SRC_DIR="$CWD_DIR/src"

# Where runtime data would be kept
RUNTIME_DIR="$CWD_DIR/runtime"

# Where RPMs would be built
RPMBUILD_DIR="$RUNTIME_DIR/rpmbuild"

# Where build RPM files would be kept
RPMS_DIR="$RPMBUILD_DIR/RPMS/x86_64"

# Where built SRPM files would be kept
SRPMS_DIR="$RPMBUILD_DIR/SRPMS"

# Where RPM spec file would be kept
RPMSPEC_DIR="$RUNTIME_DIR/rpmspec"

# Detect number of threads to run 'make' command
export THREADS=$(grep -c ^processor /proc/cpuinfo)

# Build most libraries using default GCC
export PATH=${PATH/"/usr/local/bin:"/}:/usr/local/bin

# Source libraries
. ./src/os.lib.sh
. ./src/publish_packagecloud.lib.sh
. ./src/publish_ssh.lib.sh

##
## Install all required components before building RPMs
##
function install_dependencies()
{
	echo "############################"
	echo "### Install dependencies ###"
	echo "############################"
	
	echo "####################################"
	echo "### Install development packages ###"
	echo "####################################"

	DISTRO_PACKAGES=""
	if [ $DISTR_MAJOR == 6 ]; then
		DISTRO_PACKAGES="scons"
	fi

	if ! sudo yum -y install $DISTRO_PACKAGES \
		m4 rpm-build redhat-rpm-config createrepo \
		make gcc-c++ \
		wget \
		subversion git \
		readline-devel glib2-devel unixODBC-devel \
		python-devel openssl-devel libicu-devel \
		zlib-devel libtool-ltdl-devel xz-devel
	then 
		echo "FAILED to install development packages"
		exit 1
	fi

	echo "##########################"
	echo "### Install Python 2.7 ###"
	echo "##########################"

	# select Python package for installation
	PYTHON_PACKAGE="python"
	if [ $DISTR_MAJOR == 25 ] || [ $DISTR_MAJOR == 26 ]; then
		PYTHON_PACKAGE="python2"
	elif [ $DISTR_MAJOR == 6 ]; then
		PYTHON_PACKAGE="python27"
	fi
	# and install Python
	sudo yum install -y $PYTHON_PACKAGE

	echo "###################"
	echo "### Install GCC ###"
	echo "###################"

	if [ $DISTR_MAJOR == 7 ]; then
		# Connect EPEL repository for CentOS 7 (for scons)
		if ! sudo yum -y --nogpgcheck install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm; then
			echo "FAILED to install epel"
			exit 1
		fi

		if ! sudo yum -y install scons; then
			echo "FAILED to install scons"
			exit 1
		fi
	fi


	if [ $DISTR_MAJOR == 6 ] || [ $DISTR_MAJOR == 7 ]; then
		# CentOS 6/7
		# RHEL 6/7
		# Install gcc 6 from compatibility packages

		# Enable Software Collections
		# https://www.softwarecollections.org/en/scls/rhscl/devtoolset-6/
		if os_centos; then
			sudo yum install -y centos-release-scl
		else
			# RHEL flavors

			# vanilla RHEL
			sudo yum-config-manager --enable rhel-server-rhscl-${DISR_MAJOR}-rpms

			# AWS-based RHEL
			sudo yum-config-manager --enable rhui-REGION-rhel-server-extras
			sudo yum-config-manager --enable rhui-REGION-rhel-server-optional
			sudo yum-config-manager --enable rhui-REGION-rhel-server-supplementary

			sudo yum-config-manager --enable rhui-REGION-rhel-server-rhscl
			sudo yum-config-manager --enable rhui-REGION-rhel-server-debug-rhscl
		fi

		# and install GCC6 provided by Software Collections
		sudo yum install -y devtoolset-6-gcc*

	elif [ $DISTR_MAJOR == 25 ] || [ $DISTR_MAJOR == 26 ]; then
		# Fedora 25 already has gcc 6, no need to install
		# Fedora 26 already has gcc 7, no need to install
		# Install static libs
		sudo yum install -y libstdc++-static
	fi

	echo "#################################################"
	echo "### Install MySQL client library from MariaDB ###"
	echo "#################################################"

	# which repo should be used
	# http://yum.mariadb.org/10.2/fedora26-amd64"
	# http://yum.mariadb.org/10.2/centos6-amd64"
	# http://yum.mariadb.org/10.2/centos7-amd64"
	MARIADB_REPO_URL="http://yum.mariadb.org/10.2/${OS}${DISTR_MAJOR}-amd64"

	# create repo file
	sudo bash -c "cat << EOF > /etc/yum.repos.d/mariadb.repo
[mariadb]
name=MariaDB
baseurl=${MARIADB_REPO_URL}
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF"

	sudo yum install -y MariaDB-devel MariaDB-shared

	echo "#####################"
	echo "### Install cmake ###"
	echo "#####################"

	sudo yum install -y cmake3
	#scl enable devtoolset-6 bash
}

##
##
##
function list_RPMs()
{
	echo "######################################################"
	echo "### Looking for RPMs at                            ###"
	echo "### $RPMS_DIR/clickhouse*.rpm                      ###"
	echo "######################################################"

	ls -l "$RPMS_DIR"/clickhouse*.rpm

	echo "######################################################"
}

##
##
##
function list_SRPMs()
{
	echo "######################################################"
	echo "### Looking for sRPMs at                           ###"
	echo "### $SRPMS_DIR/clickhouse*                         ###"
	echo "######################################################"

	ls -l "$SRPMS_DIR"/clickhouse*

	echo "######################################################"
}

##
## Build RPMs
##
function build_packages()
{

	echo "Prepare dirs"
	mkdir -p "$RPMBUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	mkdir -p "$RPMSPEC_DIR"

	echo "Clean up after previous run"
	rm -f "$RPMS_DIR"/clickhouse*
	rm -f "$SRPMS_DIR"/clickhouse*
	rm -f "$RPMSPEC_DIR"/*.spec

	echo "Configure RPM build environment"
	echo '%_topdir '"$RPMBUILD_DIR"'
%_smp_mflags  -j'"$THREADS" > ~/.rpmmacros

	echo "###########################"
	echo "### Create RPM packages ###"
	echo "###########################"
	cd "$RPMSPEC_DIR"
	
	# Download ClickHouse source archive
	wget --progress=dot:giga "https://github.com/yandex/ClickHouse/archive/v$CH_VERSION-$CH_TAG.zip" --output-document="$RPMBUILD_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG.zip"

	# Create spec file from template
	cat "$SRC_DIR/clickhouse.spec.in" | sed \
		-e "s/@CH_VERSION@/$CH_VERSION/" \
		-e "s/@CH_TAG@/$CH_TAG/" \
		-e "/@CLICKHOUSE_SPEC_FUNCS_SH@/ { 
r $SRC_DIR/clickhouse.spec.funcs.sh
d }" \
		> "$RPMSPEC_DIR/clickhouse.spec"
 

	echo "###############################"
	echo "### Setup path to compilers ###"
	echo "###############################"

	export CC=gcc
	export CXX=g++
	if [ $DISTR_MAJOR == 6 ] || [ $DISTR_MAJOR == 7 ]; then
		export CC=/opt/rh/devtoolset-6/root/usr/bin/gcc
		export CXX=/opt/rh/devtoolset-6/root/usr/bin/g++
	fi
	echo "CC=$CC"
	echo "CXX=$CXX"

	# Build RPMs
	echo "rpmbuild $CH_VERSION-$CH_TAG"
	rpmbuild -bs "$RPMSPEC_DIR/clickhouse.spec"
	rpmbuild -bb "$RPMSPEC_DIR/clickhouse.spec"
	echo "rpmbuild completed $CH_VERSION-$CH_TAG"

	# Display results
	list_RPMs
	list_SRPMs
}

##
##
##
function usage()
{
	echo "Usage:"
	echo "./build.sh all - install dependencies and build RPMs"
	echo "./build.sh install - do not build RPMs, just install dependencies"
	echo "./build.sh rpms - do not install dependencies, just build RPMs"
	echo "./build.sh publish packagecloud <packagecloud USER ID> - publish packages on packagecloud as USER"
	echo "./build.sh publish ssh - publish packages via SSH"
	
	exit 0
}


os_detect

if ! os_rpm_based; then
	echo "We need RPM-based OS in order to build RPM packages."
	exit 1
else
	echo "RPM-based OS detected, continue"
fi

if [ -z "$1" ]; then
	usage
fi

COMMAND="$1"

if [ "$COMMAND" == "all" ]; then
	install_dependencies
	build_packages

elif [ "$COMMAND" == "install" ]; then
	install_dependencies

elif [ "$COMMAND" == "rpms" ]; then
	build_packages

elif [ "$COMMAND" == "publish" ]; then
	PUBLISH_TARGET="$2"
	if [ "$PUBLISH_TARGET" == "packagecloud" ]; then
		# Packagecloud user id. Ex.: 123ab45678c9012d3e4567890abcdef1234567890abcdef1
		PACKAGECLOUD_ID=$3
		publish_packagecloud $PACKAGECLOUD_ID

	elif [ "$PUBLISH_TARGET" == "ssh" ]; then
		publish_ssh

	else
		echo "Unknown publish target"
		usage
	fi

else
	# unknown command
	echo "Unknown command: $COMMAND"
	usage
fi


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
#  - CentOS 6: 6.9 6.10
#  - CentOS 7: 7.4, 7.5
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
CH_VERSION="${CH_VERSION:-1.1.54388}"

# Git tag marker (stable/testing)
CH_TAG="${CH_TAG:-stable}"
#CH_TAG="${CH_TAG:-testing}"

# What sources are we going to compile - either download ready release file OR use 'git clone'
#USE_SOURCES_FROM="releasefile"
USE_SOURCES_FROM="git"

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

# Where RPMs would be built
RPMBUILD_DIR="$CWD_DIR/rpmbuild"

# Where build process will be run
BUILD_DIR="$RPMBUILD_DIR/BUILD"

# Where build RPM files would be kept
RPMS_DIR="$RPMBUILD_DIR/RPMS/x86_64"

# Where source files would be kept
SOURCES_DIR="$RPMBUILD_DIR/SOURCES"

# Where RPM spec file would be kept
SPECS_DIR="$RPMBUILD_DIR/SPECS"

# Where built SRPM files would be kept
SRPMS_DIR="$RPMBUILD_DIR/SRPMS"

# Where temp files would be kept
TMP_DIR="$RPMBUILD_DIR/TMP"

# Detect number of threads to run 'make' command
export THREADS=$(grep -c ^processor /proc/cpuinfo)

# Build most libraries using default GCC
export PATH=${PATH/"/usr/local/bin:"/}:/usr/local/bin

# Source libraries
. ./src/os.lib.sh
. ./src/publish_packagecloud.lib.sh
. ./src/publish_ssh.lib.sh

##
##
##
function set_print_commands()
{
	set -x
}

##
##
##
function banner()
{
	# disable print commands
	set +x

	# write banner

	# all params as one string
	local str="${*}"

	# str len in chars (not bytes)
	local char_len=${#str}

	# header has '## ' on the left and ' ##' on the right thus 6 chars longer that the str
	local head_len=$((char_len+6))

	# build line of required length '###########################'
	local head=""
	for i in $(seq 1 ${head_len}); do
		head="${head}#"
	done

	# build banner
	local res="${head}
## ${str} ##
${head}"

	# display banner
	echo "$res"

	# and return back print commands setting
	set_print_commands
}

##
##
##
function install_general_dependencies()
{
	banner "Install general dependencies"
	sudo yum install -y git wget curl zip unzip sed
}

##
##
##
function install_rpm_dependencies()
{
        banner "RPM build dependencies"
	sudo yum install -y rpm-build redhat-rpm-config createrepo
}

##
##
##
function install_mysql_libs()
{
	banner "Install MySQL client library"

	# which repo should be used:
	#   http://yum.mariadb.org/10.2/fedora26-amd64
	#   http://yum.mariadb.org/10.2/centos6-amd64
	#   http://yum.mariadb.org/10.2/centos7-amd64
	# however OL has to be called RHEL in this place, because Maria DB has no personal repo for OL
	if os_ol; then
		MARIADB_REPO_URL="http://yum.mariadb.org/10.2/rhel${DISTR_MAJOR}-amd64"
	else
		MARIADB_REPO_URL="http://yum.mariadb.org/10.2/${OS}${DISTR_MAJOR}-amd64"
	fi

	# create repo file
	sudo bash -c "cat << EOF > /etc/yum.repos.d/mariadb.repo
[mariadb]
name=MariaDB
baseurl=${MARIADB_REPO_URL}
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF"
	# install RPMs using newly created repo file
	sudo yum install -y MariaDB-devel MariaDB-shared
}

##
##
##
function install_build_process_dependencies()
{
	banner "Install build tools"

	sudo yum install -y m4 make

	if os_centos; then
		sudo yum install -y centos-release-scl
		sudo yum install -y devtoolset-7

		sudo yum install -y epel-release
		sudo yum install -y cmake3
	elif os_ol; then
		sudo yum install -y scl-utils
		sudo yum install -y devtoolset-7
		sudo yum install -y cmake3
	else
		# fedora
		sudo yum install -y gcc-c++ libstdc++-static cmake
	fi

	banner "Install CH dev dependencies"

	# libicu-devel -  ICU (support for collations and charset conversion functions
	# libtool-ltdl-devel - cooperate with dynamic libs
	sudo yum install -y zlib-devel openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel
}

##
##
##
function install_workarounds()
{
	banner "Install workarounds"

	# Now all workarounds are included into CMAKE_OPTIONS and MAKE_OPTIONS
}

##
## Install all required components before building RPMs
##
function install_dependencies()
{
	banner "Install dependencies"

	install_general_dependencies
	install_rpm_dependencies
	install_mysql_libs
	install_build_process_dependencies

	install_workarounds
}

##
##
##
function build_dependencies()
{
	banner "Build dependencies"
	
	if [[ $EUID -ne 0 ]]; then
		echo "You must be a root user" 2>&1
		exit 1
	fi

	if [ ! -d dependencies ]; then
		mkdir dependencies
	fi

	rm -rf dependencies/*

	cd dependencies

	banner "Install development packages"

	# Build process support requirements
	yum -y install rpm-build redhat-rpm-config gcc-c++ \
		subversion python-devel git wget m4 createrepo

	# CH dependencies

	# libicu-devel -  ICU (support for collations and charset conversion functions
	# libtool-ltdl-devel - cooperate with dynamic libs
	yum -y zlib-devel openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel

	banner "Install MySQL client library"

	if ! rpm --query mysql57-community-release; then
		yum -y --nogpgcheck install http://dev.mysql.com/get/mysql57-community-release-el${DISTR_MAJOR}-9.noarch.rpm
	fi

	yum -y install mysql-community-devel
	if [ ! -e /usr/lib64/libmysqlclient.a ]; then
		ln -s /usr/lib64/mysql/libmysqlclient.a /usr/lib64/libmysqlclient.a
	fi

	banner "Build cmake"

	wget https://cmake.org/files/v3.9/cmake-3.9.3.tar.gz
	tar xf cmake-3.9.3.tar.gz
	cd cmake-3.9.3
	./configure
	make -j $THREADS
	make install
	cd ..

	banner "Build GCC 7"

	wget http://mirror.linux-ia64.org/gnu/gcc/releases/gcc-7.2.0/gcc-7.2.0.tar.gz
	tar xf gcc-7.2.0.tar.gz
	cd gcc-7.2.0
	./contrib/download_prerequisites
	cd ..
	mkdir gcc-build
	cd gcc-build
	../gcc-7.2.0/configure --enable-languages=c,c++ --enable-linker-build-id --with-default-libstdcxx-abi=gcc4-compatible --disable-multilib
	make -j $THREADS
	make install
	hash gcc g++
	gcc --version
	ln -f -s /usr/local/bin/gcc /usr/local/bin/gcc-7
	ln -f -s /usr/local/bin/g++ /usr/local/bin/g++-7
	ln -f -s /usr/local/bin/gcc /usr/local/bin/cc
	ln -f -s /usr/local/bin/g++ /usr/local/bin/c++
	cd ..

	# Use GCC 7 for builds
	export CC=gcc-7
	export CXX=g++-7

	# Install Boost
	wget http://downloads.sourceforge.net/project/boost/boost/1.65.1/boost_1_65_1.tar.bz2
	tar xf boost_1_65_1.tar.bz2
	cd boost_1_65_1
	./bootstrap.sh
	./b2 --toolset=gcc-7 -j $THREADS
	PATH=$PATH ./b2 install --toolset=gcc-7 -j $THREADS
	cd ..

	# Clang requires Python27
	rpm -ivh http://dl.iuscommunity.org/pub/ius/stable/Redhat/6/x86_64/epel-release-6-5.noarch.rpm
	rpm -ivh http://dl.iuscommunity.org/pub/ius/stable/Redhat/6/x86_64/ius-release-1.0-14.ius.el6.noarch.rpm
	yum clean all
	yum install python27

	banner "Build Clang"

	mkdir llvm
	cd llvm
	svn co http://llvm.org/svn/llvm-project/llvm/tags/RELEASE_500/final llvm
	cd llvm/tools
	svn co http://llvm.org/svn/llvm-project/cfe/tags/RELEASE_500/final clang
	cd ../projects/
	svn co http://llvm.org/svn/llvm-project/compiler-rt/tags/RELEASE_500/final compiler-rt
	cd ../..
	mkdir build
	cd build/
	cmake -D CMAKE_BUILD_TYPE:STRING=Release ../llvm -DCMAKE_CXX_LINK_FLAGS="-Wl,-rpath,/usr/local/lib64 -L/usr/local/lib64"
	make -j $THREADS
	make install
	hash clang
	cd ../../..
}

##
##
##
function list_RPMs()
{
	banner "Looking for RPMs $RPMS_DIR/clickhouse*.rpm"
	ls -l "$RPMS_DIR"/clickhouse*.rpm
}

##
##
##
function list_SRPMs()
{
	banner "Looking for sRPMs at $SRPMS_DIR/clickhouse*"
	ls -l "$SRPMS_DIR"/clickhouse*
}

##
##
##
function mkdirs()
{
	banner "Prepare dirs"
	mkdir -p "$RPMBUILD_DIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
	mkdir -p "$TMP_DIR"
}

##
## Prepare $RPMBUILD_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG.zip file
##
function prepare_sources()
{
	banner "Ensure SOURCES dir is in place"
	mkdirs

	echo "Clean sources dir"
	rm -rf "$SOURCES_DIR"/ClickHouse*

	if [ "$USE_SOURCES_FROM" == "releasefile" ]; then
		banner "Downloading ClickHouse source archive v${CH_VERSION}-${CH_TAG}.zip"
		wget --progress=dot:giga "https://github.com/yandex/ClickHouse/archive/v${CH_VERSION}-${CH_TAG}.zip" --output-document="$SOURCES_DIR/ClickHouse-${CH_VERSION}-${CH_TAG}.zip"

	elif [ "$USE_SOURCES_FROM" == "git" ]; then
		echo "Cloning from github v${CH_VERSION}-${CH_TAG} into $SOURCES_DIR/ClickHouse-${CH_VERSION}-${CH_TAG}"

		cd "$SOURCES_DIR"

		# Go older way because older versions of git (CentOS 6.9, for example) do not understand new syntax of branches etc
		# Clone specified branch with all submodules into $SOURCES_DIR/ClickHouse-$CH_VERSION-$CH_TAG folder
		echo "Clone ClickHouse repo"
		git clone "https://github.com/yandex/ClickHouse" "ClickHouse-${CH_VERSION}-${CH_TAG}"

		cd "ClickHouse-${CH_VERSION}-${CH_TAG}"

		echo "Checkout specific tag v${CH_VERSION}-${CH_TAG}"
		git checkout "v${CH_VERSION}-${CH_TAG}"

		echo "Update submodules"
		git submodule update --init --recursive

		cd "$SOURCES_DIR"

		echo "Move files into .zip with minimal compression"
		zip -r0mq "ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "ClickHouse-${CH_VERSION}-${CH_TAG}"

		echo "Ensure .zip file is available"
		ls -l "ClickHouse-${CH_VERSION}-${CH_TAG}.zip"

		cd "$CWD_DIR"

	else
		echo "Unknows sources"
		exit 1
	fi
}

##
##
##
function build_spec_file()
{
	banner "Ensure SPECS dir is in place"
	mkdirs

	banner "Build .spec file"

	CMAKE_OPTIONS="${CMAKE_OPTIONS} -DHAVE_THREE_PARAM_SCHED_SETAFFINITY=1"
	CMAKE_OPTIONS="${CMAKE_OPTIONS} -DOPENSSL_SSL_LIBRARY=/usr/lib64/libssl.so -DOPENSSL_CRYPTO_LIBRARY=/usr/lib64/libcrypto.so -DOPENSSL_INCLUDE_DIR=/usr/include/openssl"
	CMAKE_OPTIONS="${CMAKE_OPTIONS} -DNO_WERROR=1"
		  
	MAKE_OPTIONS="${MAKE_OPTIONS}"

	# Create spec file from template
	cat "$SRC_DIR/clickhouse.spec.in" | sed \
		-e "s|@CH_VERSION@|$CH_VERSION|" \
		-e "s|@CH_TAG@|$CH_TAG|" \
		-e "s|@CMAKE_OPTIONS@|$CMAKE_OPTIONS|" \
		-e "s|@MAKE_OPTIONS@|$MAKE_OPTIONS|" \
		-e "/@CLICKHOUSE_SPEC_FUNCS_SH@/ { 
r $SRC_DIR/clickhouse.spec.funcs.sh
d }" \
		> "$SPECS_DIR/clickhouse.spec"

	banner "Looking for .spec file"
	ls -l "$SPECS_DIR/clickhouse.spec"
}


##
## Build RPMs
##
function build_RPMs()
{
	banner "Ensure build dirs are in place"
	mkdirs

	echo "Clean BUILD dir"
	rm -rf "$BUILD_DIR"/ClickHouse*

	banner "Setup RPM Macros"
	echo '%_topdir '"$RPMBUILD_DIR"'
%_tmppath '"$TMP_DIR"'
%_smp_mflags  -j'"$THREADS" > ~/.rpmmacros

	banner "Setup path to compilers"
	if os_centos || os_ol; then
		export CMAKE=cmake3
		export CC=/opt/rh/devtoolset-7/root/usr/bin/gcc
		export CXX=/opt/rh/devtoolset-7/root/usr/bin/g++
		#export CXXFLAGS="${CXXFLAGS} -Wno-maybe-uninitialized"
	else
		export CMAKE=cmake
		export CC=gcc
		export CXX=g++
	fi

	echo "CMAKE=$CMAKE"
	echo "CC=$CC"
	echo "CXX=$CXX"

	echo "cd into $CWD_DIR"
	cd "$CWD_DIR"

	banner "Build RPMs"
	rpmbuild -bs "$SPECS_DIR/clickhouse.spec"
	rpmbuild -bb "$SPECS_DIR/clickhouse.spec"
	banner "Build RPMs completed"

	# Display results
	list_RPMs
	list_SRPMs
}

##
## Build packages:
## 1. clean folders
## 2. prepare sources
## 3. build spec file
## 4. build RPMs
##
function build_packages()
{
	banner "Ensure build dirs are in place"
	mkdirs

	echo "Clean up after previous run"
	rm -f "$RPMS_DIR"/clickhouse*
	rm -f "$SRPMS_DIR"/clickhouse*
	rm -f "$SPECS_DIR"/clickhouse.spec

	banner "Create RPM packages"
	
	# Prepare $SOURCES_DIR/ClickHouse-$CH_VERSION-$CH_TAG.zip file
	prepare_sources

	# Build $SPECS_DIR/clickhouse.spec file
	build_spec_file
 
	# Compile sources and build RPMS
	build_RPMs
}

##
##
##
function usage()
{
	# disable commands print
	set +x

	echo "Usage:"
	echo
	echo "./build.sh version      - display default version to build"
	echo
	echo "./build.sh all          - most popular point of entry - the same as idep_all"
	echo
	echo "./build.sh idep_all     - install dependencies from RPMs, download CH sources and build RPMs"
	echo "./build.sh bdep_all     - build dependencies from sources, download CH sources and build RPMs !!! YOU MAY NEED TO UNDERSTAND INTERNALS !!!"
	echo
	echo "./build.sh install_deps - just install dependencies (do not download sources, do not build RPMs)"
	echo "./build.sh build_deps   - just build dependencies (do not download sources, do not build RPMs)"
	echo "./build.sh src          - just download sources"
	echo "./build.sh spec         - just create SPEC file (do not download sources, do not build RPMs)"
	echo "./build.sh packages     - download sources, create SPEC file and build RPMs (do not install dependencies)"
	echo "./build.sh rpms         - just build RPMs (do not download sources, do not create SPEC file, do not install dependencies)"
	echo
	echo "./build.sh publish packagecloud <packagecloud USER ID> - publish packages on packagecloud as USER"
	echo "./build.sh delete packagecloud <packagecloud USER ID>  - delete packages on packagecloud as USER"
	echo
	echo "./build.sh publish ssh  - publish packages via SSH"
	
	exit 0
}

##
##
##
function ensure_os_rpm_based()
{
	os_detect
	if ! os_rpm_based; then
		echo "We need RPM-based OS in order to build RPM packages."
		exit 1
	else
		echo "RPM-based OS detected, continue"
	fi
}

if [ -z "$1" ]; then
	usage
fi

COMMAND="$1"

if [ "$COMMAND" == "version" ]; then
	echo "v$CH_VERSION-$CH_TAG"

elif [ "$COMMAND" == "all" ]; then
	ensure_os_rpm_based
	set_print_commands
	install_dependencies
	build_packages

elif [ "$COMMAND" == "idep_all" ]; then
	ensure_os_rpm_based
	set_print_commands
	install_dependencies
	build_packages

elif [ "$COMMAND" == "bdep_all" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_dependencies
	build_packages

elif [ "$COMMAND" == "install_deps" ]; then
	ensure_os_rpm_based
	set_print_commands
	install_dependencies

elif [ "$COMMAND" == "build_deps" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_dependencies

elif [ "$COMMAND" == "src" ]; then
	set_print_commands
	prepare_sources

elif [ "$COMMAND" == "spec" ]; then
	set_print_commands
	build_spec_file

elif [ "$COMMAND" == "packages" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_packages

elif [ "$COMMAND" == "rpms" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_RPMs

elif [ "$COMMAND" == "publish" ]; then
	PUBLISH_TARGET="$2"

	ensure_os_rpm_based
	if [ "$PUBLISH_TARGET" == "packagecloud" ]; then
		# run publish script with all the rest of CLI params
		publish_packagecloud ${*:3}

	elif [ "$PUBLISH_TARGET" == "ssh" ]; then
		publish_ssh

	else
		echo "Unknown publish target"
		usage
	fi

elif [ "$COMMAND" == "delete" ]; then
	PUBLISH_TARGET="$2"
	if [ "$PUBLISH_TARGET" == "packagecloud" ]; then
		# run publish script with all the rest of CLI params
		publish_packagecloud_delete ${*:3}

	elif [ "$PUBLISH_TARGET" == "ssh" ]; then
		echo "Not supported yet"
	else
		echo "Unknown publish target"
		usage
	fi

else
	# unknown command
	echo "Unknown command: $COMMAND"
	usage
fi


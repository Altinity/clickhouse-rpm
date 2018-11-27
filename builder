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
CH_VERSION="${CH_VERSION:-18.14.15}"

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
CWD_DIR="$(pwd)"

# This script location dir
MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# Base dir where ClickHouse sources are expected to be located
# This is crucial when we are building from sources and 
# are standing inside sources tree
CH_SRC_ROOT_DIR=$(realpath "$MY_DIR"/..)

# Docker build context root dir
DOCKER_CONTEXT_ROOT_DIR="$MY_DIR"

# Source files dir - relative to this script
SRC_DIR="$MY_DIR/src"

# Where RPMs would be built - relative to CWD - makes possible to build in whatever folder needed
RPMBUILD_ROOT_DIR="$CWD_DIR/rpmbuild"

# Detect number of threads to run 'make' command
export THREADS=$(grep -c ^processor /proc/cpuinfo)

# Build most libraries using default GCC
#export PATH=${PATH/"/usr/local/bin:"/}:/usr/local/bin

# export LD_LIBRARY_PATH=/usr/lib:/usr/local/lib:/opt/rh/devtoolset-7/root/usr/lib64

# Source libraries
. "${SRC_DIR}"/os.lib.sh
. "${SRC_DIR}"/publish_packagecloud.lib.sh
. "${SRC_DIR}"/publish_ssh.lib.sh
. "${SRC_DIR}"/util.lib.sh

##
##
##
function set_rpmbuild_dirs()
{
	# Where RPMs would be built
	RPMBUILD_ROOT_DIR=$1

	# Where build process will be run
	BUILD_DIR="$RPMBUILD_ROOT_DIR/BUILD"

	# Where built binaries will be installed for packaging
	BUILDROOT_DIR="$RPMBUILD_ROOT_DIR/BUILDROOT"

	# Where build RPM files would be kept
	RPMS_DIR="$RPMBUILD_ROOT_DIR/RPMS/x86_64"

	# Where source files would be kept
	SOURCES_DIR="$RPMBUILD_ROOT_DIR/SOURCES"

	# Where RPM spec file would be kept
	SPECS_DIR="$RPMBUILD_ROOT_DIR/SPECS"

	# Where built SRPM files would be kept
	SRPMS_DIR="$RPMBUILD_ROOT_DIR/SRPMS"

	# Where temp files would be kept
	TMP_DIR="$RPMBUILD_ROOT_DIR/TMP"

	export BUILD_DIR
	export BUILDROOT_DIR
	export SOURCES_DIR
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
function install_build_process_dependencies()
{
	banner "Install build tools"

	sudo yum install -y make

	if os_centos; then
		sudo yum install -y epel-release
		sudo yum install -y cmake3

		sudo yum install -y centos-release-scl
		sudo yum install -y devtoolset-7
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
	sudo yum install -y openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel
	#sudo yum install -y zlib-devel openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel
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
	install_build_process_dependencies

	install_workarounds
}

##
##
##
function install_docker()
{
	sudo yum install -y yum-utils device-mapper-persistent-data lvm2
	sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
	sudo yum install -y docker-ce
	sudo systemctl start docker

	# Verify that docker is installed correctly by running the hello-world image.
	sudo docker run hello-world
}

##
##
##
function install_clickhouse_test_deps()
{
	# Install dependencies required by clickhouse-test
	sudo yum install -y epel-release
	sudo yum install -y python-lxml
	sudo yum install -y python-requests
	sudo yum install -y python2-pip
	sudo pip install termcolor

	# Install dependencies required by test scripts to be run by clickhouse-test
	sudo yum install -y perl
}

##
## Prepare $RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG.zip file
##
function prepare_sources()
{
	banner "Ensure SOURCES dir is in place"
	mkdirs

	echo "Clean sources dir"
	rm -rf "$SOURCES_DIR"/ClickHouse*

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
}

##
##
##
function build_spec_file()
{
	banner "Ensure SPECS dir is in place"
	mkdirs

	banner "Build .spec file"

	if os_centos_6; then
		# jemalloc should build as long as the Linux kernel version is >= 2.6.38, otherwise it needs to be disabled.
		# MADV_HUGEPAGE compilation error encounters
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DENABLE_JEMALLOC=0"
	fi
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DHAVE_THREE_PARAM_SCHED_SETAFFINITY=1"
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DOPENSSL_SSL_LIBRARY=/usr/lib64/libssl.so -DOPENSSL_CRYPTO_LIBRARY=/usr/lib64/libcrypto.so -DOPENSSL_INCLUDE_DIR=/usr/include/openssl"
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DNO_WERROR=1"
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DUSE_INTERNAL_ZLIB_LIBRARY=0"
		  
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

	banner "Setup RPM Macros"
	echo '%_topdir '"$RPMBUILD_ROOT_DIR"'
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

	banner "Build SRPMs"
	rpmbuild -v -bs "$SPECS_DIR/clickhouse.spec"
	
	banner "Build RPMs"
	rpmbuild -v -bb "$SPECS_DIR/clickhouse.spec"

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
function setup_local_build_dirs()
{
	# Check whether ClickHouse source dir exists
	if ! cd $CH_SRC_ROOT_DIR 2>/dev/null; then
		echo "Are we inside ClickHouse sources?"
		exit 1
	fi
	cd "$CWD_DIR"

	DOCKER_CONTEXT_ROOT_DIR="${CH_SRC_ROOT_DIR}/build"

	set_rpmbuild_dirs "${CH_SRC_ROOT_DIR}/build/rpmbuild"
}

##
##
##
function setup_local_build()
{
	setup_local_build_dirs

	# Try to extract CH version specification from sources
	# In case we can extract version spec this means we are inside CH sources
	# in case we are unable to extract version spec there is no reason to continue build

	# For v18.14.13-stable

	# Ex.: 54409
	VERSION_REVISION=$(grep "set(VERSION_REVISION" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_REVISION \(.*\)$/\1/' | sed 's/[) ].*//')

	# Ex.: 18 for v18.14.13-stable
	VERSION_MAJOR=$(grep "set(VERSION_MAJOR" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_MAJOR \(.*\)/\1/' | sed 's/[) ].*//')

	# Ex.:14 for v18.14.13-stable
	VERSION_MINOR=$(grep "set(VERSION_MINOR" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_MINOR \(.*\)/\1/' | sed 's/[) ].*//')

	# Ex.:13 for v18.14.13-stable
	VERSION_PATCH=$(grep "set(VERSION_PATCH" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_PATCH \(.*\)/\1/' | sed 's/[) ].*//')

	echo "Extracting from src: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH} rev:$VERSION_REVISION"

	if [ -z "$VERSION_MAJOR" ] || [ -z "$VERSION_MINOR" ] || [ -z "$VERSION_PATCH" ]; then
		echo "Are we inside ClickHouse sources?"
		exit 1
	fi

	# Looks like we are inside ClickHouse sources
	# We need to extract "stable" or "testing" tag/suffix to name RPMs

	# May be we are standing directly on tagged commit is git
	# Let's check this theory
	# Ex.: v18.14.13-stable
	GIT_TAG=$(cd "$CH_SRC_ROOT_DIR" && git describe --tags && cd "$CWD_DIR")
	echo "Extracting from git: $GIT_TAG"

	if [ -z "GIT_TAG" ]; then
		echo "Are those ClickHouse sources tagged?"
		exit 1
	fi

	# Extract "stable" or "testing" from git tag, which is expected to be like "v18.14.13-stable"
	# Extract everything after the first '-' in extracted git tag
	TAG=$(echo $GIT_TAG | awk -F: '{st = index($0, "-"); print substr($0, st+1)}')

	if [ -z "TAG" ]; then
		# TAG has to be specified. Expecting "stable" or "testing"
		echo "Can not recognize CH tag $TAG"
		exit 1
	fi

	# Extract version from git tag
	# Expected result v18.14.13
	# Extract everything before the first '-' in extracted git tag
	VER=$(echo $GIT_TAG | awk 'BEGIN {FS="-"}{print $1}')

	if [ "v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}" == "${VER}" ]; then
		# Version looks good
		echo "Version parsed: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}-${TAG}"
	else
		echo "Tag is not equal extracted version "
		echo "v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH} not equals ${VER}"
		exit 1
	fi

	CH_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
	CH_TAG="${TAG}"

	# Ensure build dirs are in place
	mkdirs

	# Build archive of CH sources in SOURCES

	# Figure out, how current dir is called. Fetch last entry in dir path
	# Ex.: fetch 'clickhouse' out of '/home/user/src/clickhouse'
	CH_SRC_ROOT_DIR_SHORT=${CH_SRC_ROOT_DIR##*/}

	# How link should be named - the same as .zip file should be called
	CH_SRC_ROOT_DIR_LINK="ClickHouse-${CH_VERSION}-${CH_TAG}"

	# Step one level up of current sources and make link to current sources dir
	cd ${CH_SRC_ROOT_DIR}/..
	ln -s ${CH_SRC_ROOT_DIR_SHORT} ${CH_SRC_ROOT_DIR_LINK}

	# Archive current sources dir via symlink - thus archive would
	# contain ClickHouse-18.14.13-stable folder in ClickHouse-18.14.13-stable.zip file
	# and do not include 'build' folder into archive
	rm -f "${SOURCES_DIR}/ClickHouse-${CH_VERSION}-${CH_TAG}.zip"
	zip -r0q "${SOURCES_DIR}/ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "${CH_SRC_ROOT_DIR_LINK}" -x "${CH_SRC_ROOT_DIR_LINK}/build/*"

	# Now we have .zip file in rpmbuild/SOURCES folder ready
	# Remove unused symlink - check whether it is a symlink and remove it
	cd ${CH_SRC_ROOT_DIR}/..
	[ -L ${CH_SRC_ROOT_DIR_LINK} ] && rm ${CH_SRC_ROOT_DIR_LINK}

	cd "${CWD_DIR}"
}

##
##
##
function run_test_docker()
{
	set -x
	if ! command -v docker; then
		echo "Docker is not available. Can not continue"
		exit 1
	fi

	mkdir -p $TMP_DIR

	cd $DOCKER_CONTEXT_ROOT_DIR
	if [ "$MY_DIR" != "$DOCKER_CONTEXT_ROOT_DIR" ]; then
		cp "$MY_DIR"/Dockerfile   "$DOCKER_CONTEXT_ROOT_DIR"/
		cp "$MY_DIR"/runscript.sh "$DOCKER_CONTEXT_ROOT_DIR"/
		chmod a+x "$DOCKER_CONTEXT_ROOT_DIR"/runscript.sh
	fi

	IMAGE_NAME="clickhouse_test_$(date +%s)"

	banner "Building Docker image ${IMAGE_NAME}"
	sudo docker build -t "$IMAGE_NAME" .

	banner "Running Docker image ${IMAGE_NAME}"
	#sudo docker run -it --mount src="$(pwd)",target=/clickhouse/result,type=bind $IMAGE_NAME
	sudo docker run --mount src="$TMP_DIR",target=/clickhouse/result,type=bind $IMAGE_NAME

	cd $CWD_DIR
	
	banner "Test results"
	tail $TMP_DIR/out.txt
	tail $TMP_DIR/out.code.txt
		
	echo "Test result files availbale at $TMP_DIR"
	ls -l $TMP_DIR
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
	echo "./builder version"
	echo "		display default version to build"
	echo
	echo "./builder all"
	echo "		install build deps, download sources, build RPMs"
	echo "./builder all --test"
	echo "		install build+test deps, download sources, build+test and test RPMs"
	echo
	echo "./builder install --build-deps"
	echo "		install build dependencies"
	echo "./builder install --test-deps"
	echo "		install test dependencies"
	echo "./builder install --deps"
	echo "		install all dependencies (both build and test)"
	echo "./builder install --rpms [--from-sources]"
	echo "		install RPMs, if available (do not build RPMs)"
	echo
	echo "./builder build --spec"
	echo "		just create SPEC file"
	echo "		do not download sources, do not build RPMs"
	echo "./builder build --rpms [--test]"
	echo "		download sources, build SPEC file, build RPMs"
	echo "		do not install dependencies"
	echo "./builder build --rpms --from-archive [--test]"
	echo "		just build RPMs from .zip sources"
	echo "		(do not download sources, do not create SPEC file, do not install dependencies)"
	echo "./builder build --rpms --from-unpacked-archive [--test]"
	echo "		just build RPMs from unpacked sources - most likely you have modified them"
	echo "		(do not download sources, do not create SPEC file, do not install dependencies)"
	echo "./builder build --rpms --from-sources [--test]"
	echo "		build from source codes"
	echo
	echo "./builder test --docker [--from-sources]"
	echo "./builder test --local"
	echo "./builder test --local-sql"
	echo
	echo "./builder repo --publish --packagecloud=<packagecloud USER ID>"
	echo "		publish packages on packagecloud as USER"
	echo "./builder repo --delete  --packagecloud=<packagecloud USER ID>"
	echo "		delete packages on packagecloud as USER"
	echo
	echo "./builder src --download"
	echo "		just download sources"
}

if [ -z "$1" ]; then
	usage
	exit 0
fi

#OPTIONS=$(getopt -o brg --long color:: -- "$@")
# ./getopt.sh before1 --colo -brg after1
# $OPTIONS= --color '' -b -r -g -- 'before1' 'after1'
# opt1=--color
# opt2=
# opt3=-b
# opt4=-r
# opt5=-g
# opt6=--
# opt7=before1
# opt8=after1

# Arg flags
FLAG_TEST=''
FLAG_BUILD_DEPS=''
FLAG_TEST_DEPS=''
FLAG_DEPS=''
FLAG_RPMS=''
FLAG_SPEC=''
FLAG_FROM_ARCHIVE=''
FLAG_FROM_UNPACKED_ARCHIVE=''
FLAG_FROM_SOURCES=''
FLAG_DOCKER=''
FLAG_LOCAL=''
FLAG_LOCAL_SQL=''
FLAG_PUBLISH=''
FLAG_PACKAGECLOUD=''
FLAG_DELETE=''
FLAG_DOWNLOAD=''

OPTIONS=$(getopt -o ''  --longoptions \
test,\
build-deps,\
test-deps,\
deps,\
rpms,\
spec,\
from-archive,\
from-unpacked-archive,\
from-sources,\
docker,\
local,\
local-sql,\
publish,\
packagecloud:,\
delete,\
download\
	-- "$@")

#echo "OPTIONS=$OPTIONS"
# Verify provided options
RET=$?
[ $RET -eq 0 ] || { 
	echo "Incorrect options provided"
	usage
	exit 1
}

# Apply normalized options back as agrs, so we'll be able to parse args
eval set -- "$OPTIONS"

#
# Parse args
#

# Un-dashed arg position
POSITION=0

# Array of un-dashed args
UNDASHED_ARGS=()
while true; do
	if [ "$#" == "0" ]; then
		# Number of args available - 0
		break
	fi

	# Recognize arg
	case "$1" in
	--test)
		FLAG_TEST='yes'
		;;
	--build-deps)
		FLAG_BUILD_DEPS='yes'
		;;
	--test-deps)
		FLAG_TEST_DEPS='yes'
		;;
	--deps)
		FLAG_DEPS='yes'
		;;
	--rpms)
		FLAG_RPMS='yes'
		;;
	--spec)
		FLAG_SPEC='yes'
		;;
	--from-archive)
		FLAG_FROM_ARCHIVE='yes'
		;;
	--from-unpacked-archive)
		FLAG_FROM_UNPACKED_ARCHIVE='yes'
		;;
	--from-sources)
		FLAG_FROM_SOURCES='yes'
		;;
	--docker)
		FLAG_DOCKER='yes'
		;;
	--local)
		FLAG_LOCAL='yes'
		;;
	--local-sql)
		FLAG_LOCAL_SQL='yes'
		;;
	--publish)
		FLAG_PUBLISH='yes'
		;;
	--packagecloud)
		# Arg is recognized, shift to the value, which is the next arg
		shift

		FLAG_PACKAGECLOUD=$1
		;;
	--delete)
		FLAG_DELETE='yes'
		;;
	--download)
		FLAG_DOWNLOAD='yes'
		;;
	--)
		# Just skip dashed and un-dashed args delimiter
		;;
	*)
		# Un-dashed args
		UNDASHED_ARGS[$POSITION]=$1
		POSITION=$((POSITION+1))
		;;
	esac

	# Shift to the next arg
	shift
done

UNDASHED_ARGS_NUM=${#UNDASHED_ARGS[*]}
if [[ $UNDASHED_ARGS_NUM -lt 1 ]]; then
	echo "Please provide a command"
	usage
	exit 1
fi

COMMAND=${UNDASHED_ARGS[0]}

export REBUILD_RPMS="no"
set_rpmbuild_dirs $RPMBUILD_ROOT_DIR

case $COMMAND in

version)
	echo "v$CH_VERSION-$CH_TAG"
	;;

all)
	if [ ! -z "$FLAG_TEST" ]; then
		banner "all --test"

		export TEST_BINARIES="yes"
		ensure_os_rpm_based
		set_print_commands
		# build deps
		install_dependencies
		# test deps
		install_docker
		install_clickhouse_test_deps
		# build
		build_packages
		# test
		run_test_docker

	else
		banner "all"

		ensure_os_rpm_based
		set_print_commands
		install_dependencies
		build_packages
	fi
	;;

install)
	if [ ! -z "$FLAG_BUILD_DEPS" ]; then
		banner "install --build-deps"

		ensure_os_rpm_based
		set_print_commands
		# build deps
		install_dependencies

	elif [ ! -z "$FLAG_TEST_DEPS" ]; then
		banner "install --test-deps"

		ensure_os_rpm_based
		set_print_commands
		# test deps
		install_docker
		install_clickhouse_test_deps

	elif [ ! -z "$FLAG_DEPS" ]; then
		banner "install --deps"

		ensure_os_rpm_based
		set_print_commands
		# build deps
		install_dependencies
		# test deps
		install_docker
		install_clickhouse_test_deps

	elif [ ! -z "$FLAG_RPMS" ]; then

		if [ ! -z "$FLAG_FROM_SOURCES" ]; then
			banner "install --rpms --from-sources"
			setup_local_build_dirs
		else
			banner "install --rpms"
		fi

		ensure_os_rpm_based

		RPMFILES_NUM=$(ls $RPMS_DIR/clickhouse-*.rpm 2> /dev/null|wc -l)
		if [ $RPMFILES_NUM -gt 0 ]; then
			sudo yum install -y $RPMS_DIR/clickhouse*.rpm
			sudo service clickhouse-server restart
		else
			echo "No RPM file available at $RPMS_DIR"
		fi

	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

build)
	if [ ! -z "$FLAG_SPEC" ]; then
		banner "build --spec"

		set_print_commands
		build_spec_file

	elif [ ! -z "$FLAG_RPMS" ]; then
		# build --rpms

		ensure_os_rpm_based

		export TEST_BINARIES="no"
		export REBUILD_RPMS="no"

		if [ ! -z "$FLAG_TEST" ]; then
			# build --rpms --test
			export TEST_BINARIES="yes"
		fi

		if [ -z "$FLAG_FROM_ARCHIVE" ] && [ -z "$FLAG_FROM_UNPACKED_ARCHIVE" ] && [ -z "$FLAG_FROM_SOURCES" ]; then
			banner "build --rpms [--test]"

			ensure_os_rpm_based
			set_print_commands
			build_packages

		elif [ ! -z "$FLAG_FROM_ARCHIVE" ]; then
			banner "build --rpms --from-archive [--test]"

			ensure_os_rpm_based
			set_print_commands
			build_RPMs

		elif [ ! -z "$FLAG_FROM_UNPACKED_ARCHIVE" ]; then
			banner "build --rpms --from-unpacked-archive [--test]"

			export REBUILD_RPMS="yes"
			ensure_os_rpm_based
			set_print_commands
			build_RPMs

		elif [ ! -z "$FLAG_FROM_SOURCES" ]; then
			banner "build --rpms --from-sources [--test]"

			set_print_commands
			ensure_os_rpm_based

			setup_local_build
			build_spec_file
			build_RPMs

		else
			echo "Unknwon $COMMAND path"
			exit 1
		fi
	fi
	;;

test)
	if [ ! -z "$FLAG_DOCKER" ]; then

		if [ ! -z "$FLAG_FROM_SOURCES" ]; then
			banner "test --docker --from-sources"
			setup_local_build_dirs
		else
			banner "test --docker"
		fi

		run_test_docker

	elif [ ! -z "$FLAG_LOCAL" ]; then
		banner "test --local"

		ensure_os_rpm_based

		install_clickhouse_test_deps
		clickhouse-test

	elif [ ! -z "$FLAG_LOCAL_SQL" ]; then
		banner "test --local-sql"

		echo "1) SELECT with settings"
		clickhouse-client -q 'SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1 settings enable_optimize_predicate_expression=0 FORMAT PrettyCompact'

		echo "2) SELECT w/o settings"
		clickhouse-client -q 'SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1 FORMAT PrettyCompact'

		echo "3) CREATE DATABASE qwe"
		clickhouse-client -q 'CREATE DATABASE qwe'

		echo "4) SHOW DATABASES"
		clickhouse-client -q 'SHOW DATABASES FORMAT PrettyCompact'

		echo "5) DROP DATABASE qwe"
		clickhouse-client -q 'DROP DATABASE qwe'

		echo "6) SHOW DATABASES"
		clickhouse-client -q 'SHOW DATABASES FORMAT PrettyCompact'

	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

repo)
	if [ ! -z "$FLAG_PUBLISH" ] && [ ! -z "$FLAG_PACKAGECLOUD" ]; then
		banner "repo --publish --packagecloud=ABC"

		ensure_os_rpm_based
		# For publish command files are list of undashed args after the foirst one
		FILES=("${UNDASHED_ARGS[@]:1}")
		publish_packagecloud $FLAG_PACKAGECLOUD ${FILES[@]/#/}


	elif [ ! -z "$FLAG_DELETE" ] && [ ! -z "$FLAG_PACKAGECLOUD" ]; then
		banner "repo --delete --packagecloud=ABC"

		# run publish script with all the rest of CLI params
		FILES=("${UNDASHED_ARGS[@]:1}")
		publish_packagecloud_delete ${FILES[@]/#/}
	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

src)
	if [ ! -z "$FLAG_DOWNLOAD" ]; then
		banner "src --download"

		set_print_commands
		prepare_sources

	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

*)
	echo "Unknown command $COMMAND"
	usage
	exit 1
	;;

esac


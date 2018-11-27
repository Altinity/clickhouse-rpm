FROM centos:latest

# Create work & result dirs
RUN mkdir -p /clickhouse
RUN mkdir -p /clickhouse/result

WORKDIR /clickhouse

# Install ClickHouse from local RPMs
COPY /rpmbuild/RPMS/x86_64/clickhouse-* /clickhouse/
RUN yum localinstall -y /clickhouse/*.rpm

# Install dependencies for clickhouse-test itself
RUN yum install -y epel-release
RUN yum install -y python-lxml
RUN yum install -y python-requests
RUN yum install -y python2-pip
RUN pip install termcolor

# Install dependencies required by test scripts
RUN yum install -y perl
RUN yum install -y sudo

# Install main script
COPY /runscript.sh /clickhouse/
RUN chmod a+x /clickhouse/runscript.sh


# Launch entrypoint
#CMD "/usr/bin/clickhouse-test > /clickhouse/result/result.txt 2>&1"
#CMD "/bin/bash"
CMD "./runscript.sh"

MAINTAINER Vladislav Klimenko
LABEL version="0.1"
LABEL description="Install ClickHouse RPMs and run clickhouse-test in order to verify RPMs are operational"

# IMAGE_NAME=clickhouse_test_$(date +%s)
# sudo docker build -t $IMAGE_NAME .
# sudo docker run -it --mount src="$(pwd)",target=/clickhouse/result,type=bind $IMAGE_NAME

#/usr/bin/clickhouse-server --config=/etc/clickhouse-server/config.xml
#/usr/bin/clickhouse-test > /clickhouse/result/out.txt


#docker run --ulimit nofile=90000:90000 <image-tag>
#
#First 90000 is soft limit, second 90000 is hard limit. When you launch the container, of course with -it flag, and enter command ulimit -n you’ll see the limit is 90000 now.


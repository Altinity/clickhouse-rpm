# clickhouse-rpm
Build ClickHouse RPMs

Run `build.sh` on any RHEL 6 or RHEL 7 based distribution and get ClickHouse source and binary RPM packages as an output.

```bash
Usage:

./build.sh version        - display default version to build

./build.sh all            - most popular point of entry - the same as idep_all

./build.sh idep_all       - install dependencies from RPMs, download CH sources and build RPMs
./build.sh bdep_all       - build dependencies from sources, download CH sources and build RPMs
                            !!! YOU MAY NEED TO UNDERSTAND INTERNALS !!!

./build.sh install_deps   - just install dependencies (do not download sources, do not build RPMs)
./build.sh build_deps     - just build dependencies (do not download sources, do not build RPMs)
./build.sh src            - just download sources
./build.sh spec           - just create SPEC file (do not download sources, do not build RPMs)
./build.sh packages       - download sources, create SPEC file and build RPMs (do not install dependencies)
./build.sh rpms           - just build RPMs from .zip sourcesi
                            (do not download sources, do not create SPEC file, do not install dependencies)
MYSRC=yes ./build.sh rpms - just build RPMs from unpacked sources - most likely you have modified them
                            (do not download sources, do not create SPEC file, do not install dependencies)

./build.sh publish packagecloud <packagecloud USER ID> - publish packages on packagecloud as USER
./build.sh delete packagecloud <packagecloud USER ID>  - delete packages on packagecloud as USER

./build.sh publish ssh - publish packages via SSH
```

In most cases just run `./build.sh all`

In case you'd like to just get ready RPMs look into [this repo](https://packagecloud.io/Altinity/clickhouse)


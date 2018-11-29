# clickhouse-rpm
Build ClickHouse RPMs

# Ready-to-use RPMs
In case you'd like to just get ready RPMs look into [this repo](https://packagecloud.io/Altinity/clickhouse)

# Build RPMs

Run `build.sh` on any RHEL 6 or RHEL 7 based distribution and get ClickHouse source and binary RPM packages as an output.

```bash
Usage:

./builder version
		display default version to build

./builder all
		install build deps, download sources, build RPMs
./builder all --test
		install build+test deps, download sources, build+test and test RPMs

./builder install --build-deps
		install build dependencies
./builder install --test-deps
		install test dependencies
./builder install --deps
		install all dependencies (both build and test)
./builder install --rpms [--from-sources]
		install RPMs, if available (do not build RPMs)

./builder build --spec
		just create SPEC file
		do not download sources, do not build RPMs
./builder build --rpms [--test]
		download sources, build SPEC file, build RPMs
		do not install dependencies
./builder build --rpms --from-archive [--test]
		just build RPMs from .zip sources
		(do not download sources, do not create SPEC file, do not install dependencies)
./builder build --rpms --from-unpacked-archive [--test]
		just build RPMs from unpacked sources - most likely you have modified them
		(do not download sources, do not create SPEC file, do not install dependencies)
./builder build --rpms --from-sources [--test]
		build from source codes

./builder test --docker [--from-sources]
./builder test --local
./builder test --local-sql

./builder repo --publish --packagecloud=<packagecloud USER ID>
		publish packages on packagecloud as USER
./builder repo --delete  --packagecloud=<packagecloud USER ID>
		delete packages on packagecloud as USER

./builder src --download
		just download sources

```

In most cases just run `./builder all`



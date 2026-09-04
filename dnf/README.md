# dnf/ — RPM package for openOODA

Build a `.rpm` from this directory.

## Build dependencies

```sh
sudo dnf install rpm-build rpmdevtools
rpmdev-setuptree
```

## Build

Copy the source tarball into `~/rpmbuild/SOURCES/`, then:

```sh
rpmbuild -ba dnf/openooda.spec
```

The output RPM lands in `~/rpmbuild/RPMS/<arch>/openooda-<version>-<release>.<arch>.rpm`.

## Layout

```
dnf/
├── README.md
└── openooda.spec
```

The build expects release artifacts under `dist/*-linux-*` (binaries for
all supported architectures).

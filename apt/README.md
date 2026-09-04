# apt/ — Debian package for openOODA

Build a `.deb` from this directory.

## Build dependencies

```sh
sudo apt-get install build-essential debhelper devscripts
```

## Build

Pre-stage the release tarball and built binaries in `../dist/`, then:

```sh
cd apt
make
```

This runs `dpkg-buildpackage -us -uc` and produces `../openooda_<version>-1_*.deb`.

## Layout

```
apt/
├── Makefile
├── README.md
└── debian/
    ├── changelog
    ├── compat
    ├── control
    ├── copyright
    └── rules
```

The build expects release artifacts under `../dist/*-linux-*` (binaries for
all supported architectures) and stages them into `debian/openooda/usr/bin/`
and `debian/openooda/usr/lib/openooda/`.

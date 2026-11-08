# pacman/ — Arch Linux package for openOODA

Build an Arch package from this directory.

## Build dependencies

```sh
sudo pacman -S --needed base-devel git
```

## Build

Pre-stage the release tarball and built binaries in `../dist/`, then:

```sh
cd pacman
makepkg
sudo pacman -U openooda-0.1.0-1-x86_64.pkg.tar.zst
```

Use `makepkg -si` to install dependencies automatically.

## Layout

```
pacman/
├── README.md
└── PKGBUILD
```

The build expects release artifacts under `../dist/*-linux-*` (binaries for
all supported architectures).

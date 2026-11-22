Name:           openooda
Version:        2.4.0
Release:        1%{?dist}
Summary:        openOODA — Primary Systems Language for the AI Era
URL:            https://openooda.org
Source0:        https://github.com/openOODA/install/archive/v%{version}.tar.gz
BuildArch:      x86_64 aarch64
BuildRequires:  git
Requires:       glibc

%description
openOODA — Primary Systems Language for the AI Era.

The openOODA toolchain: driver, compiler, runtime, standard library,
package manager, language server, MCP server, and terminal UI.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/openooda
mkdir -p %{buildroot}/etc/profile.d
for f in %{_sourcedir}/../dist/*-linux-*; do
  [ -f "$f" ] || continue
  case "$f" in
    *.a|*libooda-runtime.a*)
      install -m 0644 "$f" %{buildroot}/usr/lib/openooda/libooda-runtime.a ;;
    *)
      b=$(basename "$f" | sed -E 's/-linux-(x86_64|arm64)$//')
      install -m 0755 "$f" "%{buildroot}/usr/bin/$b" ;;
  esac
done
git clone --depth 1 https://github.com/openOODA-core/ooda-standard %{buildroot}/usr/lib/openooda/ooda-standard
rm -rf %{buildroot}/usr/lib/openooda/ooda-standard/.git
install -m 0644 %{_sourcedir}/profile.d.sh %{buildroot}/etc/profile.d/openooda.sh

%files
/usr/bin/*
/usr/lib/openooda/*
/etc/profile.d/openooda.sh

%changelog
* Sat Nov 21 2026 openOODA Authors <ops@openooda.org> - 2.4.0-1
- Sync packaging with VERSION 2.4.0; ship ooda-calendar v0.1.0, ooda-flasher v0.5.0, ooda-screenshot v0.1.0 (72 pkgs)
* Sat Nov 21 2026 openOODA Authors <ops@openooda.org> - 2.3.0-1
- Sync packaging with VERSION 2.3.0; ship ooda-clock v0.1.0, ooda-calculator v0.3.0, ooda-passwords v0.5.0, and ooda-voxel v0.2.1 feedback (70 pkgs)
* Sat Nov 21 2026 openOODA Authors <ops@openooda.org> - 2.2.0-1
- Sync packaging with VERSION 2.2.0; retire ooda-audio, rename ooda-store -> ooda-software v0.9.0, bump ooda-photos v0.7.0 (69 pkgs)
* Tue Nov 17 2026 openOODA Authors <ops@openooda.org> - 2.0.0-1
- Sync packaging with VERSION 2.0.0; canonical ooda-<word> cutover (oodac -> ooda-compiler, oostd -> ooda-standard)
* Sun Nov 15 2026 openOODA Authors <ops@openooda.org> - 0.2.9-1
- Sync packaging with VERSION 0.2.9
* Sun Nov 15 2026 openOODA Authors <ops@openooda.org> - 0.2.8-1
- Sync packaging with VERSION 0.2.8
* Sun Nov 15 2026 openOODA Authors <ops@openooda.org> - 0.2.7-1
- Sync packaging with VERSION 0.2.7
* Fri Nov 06 2026 openOODA Authors <ops@openooda.org> - 0.2.6-1
- Sync packaging with VERSION 0.2.6; umbrella-release assets; license corrected to Apache-2.0
* Thu Sep 10 2026 openOODA Authors <ops@openooda.org> - 0.1.30-1
- Sync packaging with VERSION 0.1.30, add blackbox, strip arch suffixes
* Thu Sep 03 2026 openOODA Authors <ops@openooda.org> - 0.1.0-1
- Initial RPM package

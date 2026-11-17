Name:           openooda
Version:        2.0.0
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
    *.a|*liboodar.a*)
      install -m 0644 "$f" %{buildroot}/usr/lib/openooda/liboodar.a ;;
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

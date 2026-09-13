Name:           openooda
Version:        0.1.30
Release:        1%{?dist}
Summary:        openOODA — Primary Systems Language for the AI Era
License:        MIT
URL:            https://openooda.org
Source0:        https://github.com/openOODA/install/archive/v%{version}.tar.gz
BuildArch:      x86_64 aarch64
BuildRequires:  git
Requires:       glibc

%description
openOODA — Primary Systems Language for the AI Era.

The openOODA toolchain: driver, compiler, runtime, standard library,
package manager, language server, MCP server, and flight recorder (blackbox).

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
git clone --depth 1 https://github.com/openOODA/std %{buildroot}/usr/lib/openooda/std
rm -rf %{buildroot}/usr/lib/openooda/std/.git
install -m 0644 %{_sourcedir}/profile.d.sh %{buildroot}/etc/profile.d/openooda.sh

%files
/usr/bin/*
/usr/lib/openooda/*
/etc/profile.d/openooda.sh

%changelog
* Thu Sep 10 2026 openOODA Authors <ops@openooda.org> - 0.1.30-1
- Sync packaging with VERSION 0.1.30, add blackbox, strip arch suffixes
* Thu Sep 03 2026 openOODA Authors <ops@openooda.org> - 0.1.0-1
- Initial RPM package

Name:           openooda
Version:        0.1.0
Release:        1%{?dist}
Summary:        openOODA — Sovereign Systems Language for the AI Era
License:        MIT
URL:            https://openooda.org
Source0:        https://github.com/openOODA/packaging/archive/v%{version}.tar.gz
BuildArch:      x86_64 aarch64
Requires:       glibc

%description
openOODA — Sovereign Systems Language for the AI Era.

The openOODA toolchain: driver, compiler, runtime, standard library,
package manager, language server, and MCP server.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/openooda
if ls %{_sourcedir}/../dist/*-linux-* >/dev/null 2>&1; then
  install -m 0755 %{_sourcedir}/../dist/*-linux-* %{buildroot}/usr/bin/
fi
if ls %{_sourcedir}/../dist/*-linux-*.a >/dev/null 2>&1; then
  install -m 0644 %{_sourcedir}/../dist/*-linux-*.a %{buildroot}/usr/lib/openooda/
fi

%files
/usr/bin/*
/usr/lib/openooda/*

%changelog
* Thu Sep 03 2026 openOODA Authors <ops@openooda.org> - 0.1.0-1
- Initial RPM package

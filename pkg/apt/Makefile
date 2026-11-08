.PHONY: build clean

build:
	dpkg-buildpackage -us -uc

clean:
	dh clean
	rm -f ../openooda_*.deb ../openooda_*.changes ../openooda_*.buildinfo

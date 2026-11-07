.PHONY: all build test test-swift test-lua install clean

all: build

build:
	scripts/build.sh

test: test-swift test-lua

test-swift:
	cd helper && swift test

test-lua:
	lua plugin/tests/run_tests.lua

install: build
	scripts/install.sh

clean:
	rm -rf build helper/.build

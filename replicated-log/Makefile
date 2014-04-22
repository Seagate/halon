
build: configure
	cabal build

configure:
	cabal clean
	cabal configure --enable-tests

clean:
	cabal clean

install: build
	cabal copy
	cabal register

configure-dev:
	cabal clean
	cabal-dev configure --enable-tests -frandomTests -s $(SANDBOX)

build-dev: configure-dev
	cabal build

install-dev:
	cabal-dev copy -s $(SANDBOX)
	cabal-dev register -s $(SANDBOX)

haddock:
	cabal haddock

test:
	dist/build/tests/tests -p ut
	dist/build/tests/tests -p durability FirstPass
	dist/build/tests/tests -p durability SecondPass

test-dev:
	dist/build/random/random

ci: build test install build-dev test-dev install-dev haddock 

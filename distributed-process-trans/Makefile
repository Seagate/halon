
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
	cabal-dev configure --enable-tests -s $(SANDBOX)

build-dev: configure-dev
	cabal build

install-dev:
	cabal-dev copy -s $(SANDBOX)
	cabal-dev register -s $(SANDBOX)

haddock:
	cabal haddock

test test-dev:

ci: build test install build-dev test-dev install-dev haddock 

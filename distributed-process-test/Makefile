build: sandbox configure
	cabal build

sandbox:
	cabal sandbox init --sandbox=$(SANDBOX)

configure: sandbox
	cabal configure --enable-tests

clean:
	cabal clean


install: build
	cabal copy
	cabal register

haddock:
	cabal haddock

test-and-install: test install

test: configure

ci: clean build test install haddock

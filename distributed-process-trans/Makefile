
build: configure
	cabal build

configure:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal clean
	cabal configure --enable-tests

clean:
	cabal clean

install: build
	cabal copy
	cabal register

haddock:
	cabal haddock

test:

ci: build test install haddock 

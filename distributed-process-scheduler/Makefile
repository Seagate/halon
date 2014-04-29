
build: configure
	cabal build

configure:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal clean
ifdef RANDOMIZED_TESTS
	cabal configure --enable-tests -fuse-scheduler
else
	cabal configure --enable-tests
endif

clean:
	cabal clean

install: build
	cabal copy
	cabal register

haddock:
	cabal haddock

test:
	dist/build/unit-tests/unit-tests

ci: build test install haddock 

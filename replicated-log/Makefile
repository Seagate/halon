build: configure
	cabal build

configure:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal clean
ifdef RANDOMIZED_TESTS
	cabal configure --enable-tests -frandomTests
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
ifdef RANDOMIZED_TESTS
	dist/build/random/random
else
	dist/build/tests/tests --pattern ut --num-threads 1
	dist/build/tests/tests --pattern durability --num-threads 1 -- FirstPass
	dist/build/tests/tests --pattern durability --num-threads 1 -- SecondPass
endif

ci: build test install haddock 

CABAL = cabal $(CABAL_SANDBOX)

build: configure
	$(CABAL) build

configure: deps
	$(CABAL) configure --enable-tests

deps:
	-$(CABAL) install --enable-tests --dependencies-only

clean:
	$(CABAL) clean

install: build
	$(CABAL) copy
	$(CABAL) register

haddock:
	$(CABAL) haddock

test:

ci: clean build test install haddock 

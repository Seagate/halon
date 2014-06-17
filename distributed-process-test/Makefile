CABAL = cabal $(CABAL_SANDBOX)
ifdef RANDOMIZED_TESTS
CABAL += --builddir=dist-scheduer
CABAL_FLAGS += -fuse-scheduler
endif

build: configure
	$(CABAL) build

deps:
	-$(CABAL) install --enable-tests --only-dependencies

configure: deps
	$(CABAL) configure --enable-tests

clean:
	$(CABAL) clean


install: build
	$(CABAL) copy
	$(CABAL) register

haddock:
	$(CABAL) haddock

test: 

ci: clean build test install haddock

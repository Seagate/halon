CABAL = cabal $(CABAL_SANDBOX)
ifdef RANDOMIZED_TESTS
CABAL += --builddir=dist-scheduler
CABAL_FLAGS += -fuse-scheduler
TEST = dist-scheduler/build/unit-tests/unit-tests
else
TEST = dist/build/unit-tests/unit-tests
endif


build: configure
	$(CABAL) build

dep:
	-$(CABAL) install --only-dependencies --enable-tests --reorder-goals

configure: dep
	$(CABAL) configure --enable-tests $(CABAL_FLAGS)

clean:
	$(CABAL) clean

install: build
	$(CABAL) copy
	$(CABAL) register

haddock:
	$(CABAL) haddock

$(TEST): build

test: $(TEST)
	$(TEST)

ci: clean build test install haddock 

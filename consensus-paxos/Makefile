CABAL = cabal $(CABAL_SANDBOX)
ifdef RANDOMIZED_TESTS
TEST     = dist-scheduler/build/random/random
CABAL   += --builddir=dist-scheduler
CABAL_FLAGS  += -frandomTests
else
TEST    = dist/build/tests/tests
endif

build: configure
	$(CABAL) build

configure: dep 
	$(CABAL) configure --enable-tests $(CABAL_FLAGS)

clean:
	$(CABAL) clean

install: build
	$(CABAL) copy
	$(CABAL) register

haddock:
	$(CABAL) haddock

dep:
ifdef RANDOMIZED_TESTS
	@echo "Installing distributed-process-scheduler with scheduler enabled"
	-$(CABAL) $(CABAL_FLAGS) install distributed-process-scheduler -fuse-scheduler
endif
	-$(CABAL) install --only-dependencies --enable-tests --reorder-goals


test: $(TEST)
	$(TEST)

$(TEST): build

promela:
	make -C promela test

ci: clean build test install promela haddock

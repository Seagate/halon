CABAL = cabal $(CABAL_SANDBOX)
ifdef RANDOMIZED_TESTS
CABAL_FLAGS  += -frandomTests
TEST     = dist-scheduler/build/random/random
CABAL  += --builddir=dist-scheduler
else
TEST     = dist/build/tests/tests
endif


build: configure
	$(CABAL) build

dep:
ifdef RANDOMIZED_TESTS
	@echo "Installing distributed-process-scheduler with scheduler enabled"
	-$(CABAL) $(CABAL_FLAGS) install distributed-process-scheduler -fuse-scheduler
endif
	-$(CABAL) install --only-dependencies --enable-tests --reorder-goals


configure: dep 
	$(CABAL) configure --enable-tests $(CABAL_FLAGS)

CABAL  += --builddir=$(BUILDDIR)

build: configure
	$(CABAL) build

dep:
	$(CABAL) install --only-dependencies --enable-tests --reorder-goals || echo "..skipping dependency installation"

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
ifdef RANDOMIZED_TESTS
	$(TEST)
else
	$(TEST) --pattern ut --num-threads 1
	$(TEST) --pattern durability --num-threads 1 -- FirstPass
	$(TEST) --pattern durability --num-threads 1 -- SecondPass
endif

ci: clean build test install haddock 

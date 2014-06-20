CABAL = cabal $(CABAL_SANDBOX)

build: configure
	$(CABAL) build

configure: dep
	$(CABAL) configure --enable-tests

dep:
	@echo "Preparing sandbox"
ifdef RANDOMIZED_TESTS
	@echo "Installing distributed-process-scheduler with scheduler enabled"
	-$(CABAL) $(CABAL_FLAGS) install distributed-process-scheduler -fuse-scheduler
endif
	-$(CABAL) install --only-dependencies --enable-tests --reorder-goals

clean:
	$(CABAL) clean

install: build
	$(CABAL) copy
	$(CABAL) register

haddock:
	$(CABAL) haddock

test:

ci: clean build test install haddock 

ifdef RANDOMIZED_TESTS
BUILDDIR = dist-schedule
TEST     = $(BUILDDIR)/build/random/random
CABAL_FLAGS  += -frandomTests
else
BUILDDIR = dist
TEST     = $(BUILDDIR)/build/tests/tests
endif
CABAL_FLAGS  += --builddir=$(BUILDDIR)

build: configure
	cabal build --builddir=$(BUILDDIR)

configure: sandbox
	cabal configure --enable-tests $(CABAL_FLAGS)

clean:
	cabal clean --builddir=$(BUILDDIR)

install: build
	cabal copy --builddir=$(BUILDDIR)
	cabal register --builddir=$(BUILDDIR)

haddock:
	cabal haddock --builddir=$(BUILDDIR)

sandbox: 
	@echo "Preparing sandbox"
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal sandbox add-source \
		../distributed-process-scheduler \
		../distributed-process-test \
		../consensus
ifdef RANDOMIZED_TESTS
	@echo "Installing distributed-process-scheduler with scheduler enabled"
	cabal install distributed-process-scheduler -fuse-scheduler
endif
	cabal install --only-dependencies --enable-tests --reorder-goals || echo "it not required"

test: $(TEST)

$(TEST): build
	$(TEST)

promela:
	make -C promela test

ci: build test install promela haddock

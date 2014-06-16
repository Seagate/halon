ifdef RANDOMIZED_TESTS
BUILDDIR=dist-schedule
CABAL_FLAGS += -fuse-scheduler
else
BUILDDIR=dist
endif
CABAL_FLAGS += --builddir=$(BUILDDIR)


build: sandbox configure
	cabal build --builddir=$(BUILDDIR)

sandbox:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal sandbox add-source \
		../distributed-process-trans --snapshot
	cabal install --only-dependencies --enable-tests --reorder-goals || echo "is not required"

configure:
	cabal configure --enable-tests $(CABAL_FLAGS)

clean:
	cabal clean --builddir=$(BUILDDIR)

install: build
	cabal copy --builddir=$(BUILDDIR)
	cabal register --builddir=$(BUILDDIR)

haddock:
	cabal haddock --builddir=$(BUILDDIR)

test: build 
	$(BUILDDIR)/build/unit-tests/unit-tests

ci: build test install haddock 

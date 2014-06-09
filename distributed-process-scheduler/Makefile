ifdef RANDOMIZED_TESTS
BUILDDIR=dist-schedule
CFLAGS += -fuse-scheduler
else
BUILDDIR=dist
endif
CFLAGS += --builddir=$(BUILDDIR)


build: sandbox configure
	cabal build --builddir=$(BUILDDIR)

sandbox:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal sandbox add-source \
		../distributed-process-trans --snapshot
	cabal install --only-dependencies --enable-tests --reorder-goals || echo "is not required"

configure:
	cabal configure --enable-tests $(CFLAGS)

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

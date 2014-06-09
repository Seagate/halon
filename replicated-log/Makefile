ifdef RANDOMIZED_TESTS
BUILDDIR = dist-schedule
CFLAGS  += -frandomTests
TEST     = $(BUILDDIR)/build/random/random
else
BUILDDIR = dist
TEST     = $(BUILDDIR)/build/tests/tests
endif

CFLAGS  += --builddir=$(BUILDDIR)

build: configure
	cabal build --builddir=$(BUILDDIR)

sandbox:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal sandbox add-source --snapshot \
		../consensus \
		../consensus-paxos
	cabal install --only-dependencies --enable-tests --reorder-goals || echo "not installing"

configure: sandbox
	cabal configure --enable-tests $(CFLAGS)

clean:
	cabal clean --builddir=$(BUILDDIR)

install: build
	cabal copy --builddir=$(BUILDDIR)
	cabal register --builddir=$(BUILDDIR)

haddock:
	cabal haddock --builddir=$(BUILDDIR)

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

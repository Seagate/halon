
build: configure
	cabal build

configure:
	cabal clean
	cabal configure --enable-tests

sandbox:
	echo "Preparing sandbox"
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal sandbox add-source \
		../distributed-process-scheduler
	cabal install --only-dependencies --enable-tests --reorder-goals || echo "already installed"

clean:
	cabal clean

install: build
	cabal copy
	cabal register

haddock:
	cabal haddock

test: sandbox build 

ci: build test install haddock 

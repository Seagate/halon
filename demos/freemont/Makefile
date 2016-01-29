IP=10.0.2.15
MERO_ROOT=/mero
HALON_ROOT=/home/vagrant/mero/halon/
BIN_DIR=/home/vagrant/

all: 1.install-mero.done 2.install-halon.done 3.run-halond.done 4.run-mero.done

halon_facts.yaml: halon_facts.yaml.in
	sed "s/\%IP\%/$(IP)/g" halon_facts.yaml.in > halon_facts.yaml

1.install-mero.done: 1.install-mero
	cd $(MERO_ROOT) \
		sudo sh autogen.sh && sudo ./configure --enable-debug && sudo make -j4
	touch 1.install-mero.done

2.install-halon.done: 2.install-halon
	cd $(HALON_ROOT) \
		stack clean rpclite --flag mero-halon:mero --no-docker ; \
                MERO_ROOT=$(MERO_ROOT) LD_LIBRARY_PATH=$(MERO_ROOT)/mero/.libs \
			stack install --flag mero-halon:mero --no-docker
	touch 2.install-halon.done

3.run-halond.done: 3.run-halond 2.install-halon.done
	BIN_DIR=$(BIN_DIR) MERO_ROOT=$(MERO_ROOT) IP=$(IP) sudo -E ./run-halond.sh
	touch 3.run-halond.done

4.run-mero.done: 4.run-mero 3.run-halond.done 1.install-mero.done
	MERO_ROOT=$(MERO_ROOT) BIN_DIR=$(BIN_DIR) IP=$(IP) ./mero-singlenode.sh
	touch 4.run-mero.done

5.write-data.done: 5.write-data 4.run-mero.done
	./write_data.sh

wrkclean:
	sudo rm -rf halon-persistence
	sudo rm -rf m0trace.*

clean: 
	rm *.done

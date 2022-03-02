//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#include "rpclite.h"

#include "lib/memory.h"

#include <stdio.h>
#include <string.h>

bool received;

int rcv(rpc_item_t* it,void* ctx) {
	//fprintf(stderr,"\nrcv callback: %s %d\n",rpc_get_fragment(it,0),rpc_get_fragments_count(it));
    return 0;
}

void reply_rcv(rpc_connection_t* c,void* ctx,rpc_status_t st) {
	//fprintf(stderr,"\nreply rcv: %p %d\n",ctx,st);
    received = true;
}

int main(int argc,char** argv) {
	int rc = m0_init_wrapper();
	fprintf(stderr,"m0_init: %d\n",rc);

	rc = rpc_init("");
	fprintf(stderr,"rpc_init: %d\n",rc);

	//if (argc>1)
    {

		rpc_endpoint_t* e;

		rc = rpc_listen("0@lo:12345:34:10",&(rpc_listen_callbacks_t){ .receive_callback=rcv },&e);
		fprintf(stderr,"rpc_listen: %d\n",rc);

		rpc_connection_t* c;
		rpc_connection_t* c2;

		rc = rpc_connect(e,"0@lo:12345:34:10",3,&c);
		fprintf(stderr,"rpc_connect: %d\n",rc);

		rc = rpc_connect(e,"0@lo:12345:34:10",3,&c2);
		fprintf(stderr,"rpc_connect: %d\n",rc);

		struct iovec segments[] = { { .iov_base = "segment 1", .iov_len = 9 }
								, { .iov_base = "segment 2", .iov_len = 10 }
								};

		//rc = rpc_send_blocking(c,segments,2,2);

		//struct iovec* segments = (struct iovec*)c2_alloc(2*sizeof(struct iovec));
		//segments[0] = (struct iovec) { .iov_base = "segment 1", .iov_len = 10 };
		//segments[1] = (struct iovec) { .iov_base = "segment 2", .iov_len = 10 };
		rc = rpc_send_blocking(c,segments,2,1);
		fprintf(stderr,"rpc_send_blocking: %d\n",rc);

        int i;
        for(i=0;i<100000;i+=1) {
            received=false;
	    	rc = rpc_send(c2,segments,2,reply_rcv,(void*)5,2);
			if (rc) {
				fprintf(stderr,"rpc_send: %d\n",rc);
				break;
			}
            while(!received);
            if (i%100==0)
                fprintf(stderr,"%d\n",i);
        }

		rc = rpc_disconnect(c,2);
		fprintf(stderr,"rpc_disconnect: %d\n",rc);
		rc = rpc_disconnect(c2,2);
		fprintf(stderr,"rpc_disconnect: %d\n",rc);

		rpc_destroy_endpoint(e);
	}

    rpc_fini();

	return 0;
}

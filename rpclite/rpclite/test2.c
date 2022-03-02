//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#include "rpclite.h"

#include "lib/memory.h"
#include "lib/thread.h"
#include "lib/misc.h"

#include <stdio.h>
#include <string.h>

int rcv(rpc_item_t* it,void* ctx) {
    if (rpc_get_fragments_count(it)==2)
    	fprintf(stderr,"\nrcv callback: %s %d\n",rpc_get_fragment(it,0),rpc_get_fragments_count(it));
    else
    	fprintf(stderr,"\nrcv callback: %d\n",rpc_get_fragments_count(it));
    return 0;
}

void reply_rcv(rpc_connection_t* c,void* ctx,rpc_status_t st) {
	fprintf(stderr,"\nreply rcv: %p %d\n",ctx,st);
}

static void* cclose(rpc_connection_t* c) {
		int rc = rpc_disconnect(c,2);
		fprintf(stderr,"rpc_disconnect: %d\n",rc);
		return NULL;
}

int main(int argc,char** argv) {
	int rc = m0_init_wrapper();
	fprintf(stderr,"m0_init: %d\n",rc);

	rc = rpc_init("");
	fprintf(stderr,"rpc_init: %d\n",rc);

	if (argc>1) { // server code

		rpc_endpoint_t* e;

		rc = rpc_listen("0@lo:12345:34:10",&(rpc_listen_callbacks_t){ .receive_callback=rcv },&e);
		fprintf(stderr,"rpc_listen: %d\n",rc);

		char ch;
		printf("running server ... (type enter to finish)");
		scanf("%c",&ch);

		rpc_destroy_endpoint(e);

	} else { // client code

		struct m0_thread thread;

		rpc_endpoint_t* e;
		rpc_connection_t* c;

		rc = rpc_create_endpoint("0@lo:12345:34:2",&e);
		fprintf(stderr,"rpc_create_endpoint: %d\n",rc);


		rc = rpc_connect(e,"0@lo:12345:34:10",3,&c);
		fprintf(stderr,"rpc_connect: %d\n",rc);

		struct iovec segments[] = { { .iov_base = "segment 1", .iov_len = 10 }
								, { .iov_base = "segment 2", .iov_len = 10 }
								};

		rc = rpc_send_blocking(c,segments,2,1);
		fprintf(stderr,"rpc_send_blocking: %d\n",rc);

		rc = rpc_send(c,segments,2,reply_rcv,(void*)5,2);
		fprintf(stderr,"rpc_send: %d\n",rc);

		sleep(2);

		M0_SET0(&thread);
		rc = M0_THREAD_INIT(&thread, rpc_connection_t*, NULL, (void *) &cclose, c, "cclose");
		fprintf(stderr,"cclose_thread_init: %d\n",rc);
		rc = m0_thread_join(&thread);
		fprintf(stderr,"post m0_thread_join: %d\n",rc);

		rpc_destroy_endpoint(e);

	}

		rpc_fini();

	return 0;
}

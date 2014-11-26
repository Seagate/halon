//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#include "rpclite.h"

#include "lib/memory.h"
#include "lib/thread.h"
#include "lib/misc.h"

#include <pthread.h>
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

static void* cclose(void* c) {
    int rc;
		rc = rpc_disconnect((rpc_connection_t*)c,2);
		fprintf(stderr,"rpc_disconnect: %d\n",rc);
    return NULL;
}

int main(int argc,char** argv) {
	int rc = rpc_init("");
	fprintf(stderr,"rpc_init: %d\n",rc);

	if (argc>1) { // server code

		rpc_receive_endpoint_t* re;

		rc = rpc_listen("s1","0@lo:12345:34:500",&(rpc_listen_callbacks_t){ .receive_callback=rcv },&re);
		fprintf(stderr,"rpc_listen: %d\n",rc);

		char ch;
		printf("running server ... (type enter to finish)");
		scanf("%c",&ch);

		rpc_stop_listening(re);

	} else { // client code

        pthread_t thread;

		rpc_endpoint_t* e;
		rpc_connection_t* c;

		rc = rpc_create_endpoint("0@lo:12345:34:2",&e);
		fprintf(stderr,"rpc_create_endpoint: %d\n",rc);


		rc = rpc_connect(e,"0@lo:12345:34:500",3,&c);
		fprintf(stderr,"rpc_connect: %d\n",rc);

		struct iovec segments[] = { { .iov_base = "segment 1", .iov_len = 10 }
								, { .iov_base = "segment 2", .iov_len = 10 }
								};

		rc = rpc_send_blocking(c,segments,2,1);
		fprintf(stderr,"rpc_send_blocking: %d\n",rc);

		rc = rpc_send(c,segments,2,reply_rcv,(void*)5,2);
		fprintf(stderr,"rpc_send: %d\n",rc);

        sleep(2);

        rc = pthread_create(&thread,NULL,&cclose,c);
		fprintf(stderr,"c2_thread_init: %d\n",rc);

        pthread_join(thread,NULL);

		rpc_destroy_endpoint(e);

	}
	
    rpc_fini();

	return 0;
}


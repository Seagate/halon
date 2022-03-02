//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#include "rpclite.h"
#include "m0init.h"

#include "lib/memory.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define NUM_THREADS 10

void reply_rcv(rpc_connection_t* c,void* ctx,rpc_status_t st) {
	//fprintf(stderr,"\nreply rcv: %p %d\n",ctx,st);
}

int rcv(rpc_item_t* it,void* ctx) {
    return 0;
}

rpc_endpoint_t* e;


//void* threadMain(void* d) {
void threadMain(void* d) {
    int rc;
	rpc_connection_t* c;

	rc = rpc_connect(e,"0@lo:12345:34:10",5,&c);
    if (rc) {
        fprintf(stderr,"rpc_connect: %d\n",rc);
        return;
    }

    int sz = m0_rpc_session_get_max_item_size(rpc_get_session(c))-128-4;
    void* buf = m0_alloc(sz);

	struct iovec segments[] = { { .iov_base = buf, .iov_len = sz }
						      };

	rc = rpc_send(c,segments,1,reply_rcv,(void*)5,3);
    if (rc)
    	fprintf(stderr,"rpc_send: %d\n",rc);

    sleep(5);
	rc = rpc_disconnect(c,2);
    if (rc)
        fprintf(stderr,"rpc_disconnect: %d\n",rc);
    m0_free(buf);

//    return 0;
}

int main(int argc,char** argv) {
	int rc = m0_init_wrapper();
	fprintf(stderr,"m0_init: %d\n",rc);

	rc = rpc_init("");
	fprintf(stderr,"rpc_init: %d\n",rc);

	rc = rpc_listen("0@lo:12345:34:10",&(rpc_listen_callbacks_t){ .receive_callback=rcv },&e);
	fprintf(stderr,"rpc_listen: %d\n",rc);

	rpc_connection_t* c;
	rc = rpc_connect(e,"0@lo:12345:34:10",5,&c);
    if (rc) {
    	fprintf(stderr,"rpc_connect: %d\n",rc);
        return 0;
    }

    fprintf(stderr,"m0_rpc_session_get_max_item_size: %d\n",m0_rpc_session_get_max_item_size(rpc_get_session(c)));
	rc = rpc_disconnect(c,2);
    if (rc)
        fprintf(stderr,"rpc_disconnect: %d\n",rc);

    int i;
    //pthread_t thread[NUM_THREADS];
    struct m0_thread thread[NUM_THREADS];
    for(i=0;i<NUM_THREADS;i+=1) {
        M0_SET0(&thread[i]);
        rc = M0_THREAD_INIT(&thread[i], void*, NULL, &threadMain, NULL, "client_%d", i);
        M0_ASSERT(rc == 0);
        //if (pthread_create(&thread[i],NULL,&threadMain,NULL))
        //     fprintf(stderr,"pthread_create error\n");
    }
    for(i=0;i<NUM_THREADS;i+=1)
		m0_thread_join(&thread[i]);
        //pthread_join(thread[i],NULL);


    fprintf(stderr,"leaving...\n");

	rpc_destroy_endpoint(e);

    rpc_fini();

	return 0;
}

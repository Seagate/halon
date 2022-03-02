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
    return 0;
}

int main(int argc,char** argv) {
	int rc = m0_init_wrapper();
	fprintf(stderr,"m0_init: %d\n",rc);

	rc = rpc_init("");
	fprintf(stderr,"rpc_init: %d\n",rc);

    if (argc>1) {

	rpc_endpoint_t* e;

	rc = rpc_listen("0@lo:12345:34:10",&(rpc_listen_callbacks_t){ .receive_callback=rcv },&e);
	fprintf(stderr,"rpc_listen: %d\n",rc);

    char c;
    fprintf(stderr,"type enter ...");
    scanf("%c",&c);
	rpc_destroy_endpoint(e);

    } else {

	rpc_endpoint_t* e;

	rpc_connection_t* c;

	rc = rpc_create_endpoint("0@lo:12345:34:2",&e);
	fprintf(stderr,"rpc_create_endpoint: %d\n",rc);

	rc = rpc_connect(e,"0@lo:12345:34:10",3,&c);
	fprintf(stderr,"rpc_connect: %d\n",rc);

    char arr0[1024*32];
	struct iovec segments[] = { { .iov_base = arr0, .iov_len = sizeof(arr0) }
	//						, { .iov_base = arr0, .iov_len = sizeof(arr0) }
							};
	fprintf(stderr,"%d\n",segments[0].iov_len);

    int i;
    for(i=0;i<200;i+=1) {
	  	rc = rpc_send_blocking(c,segments,1,1);
		if (rc) {
			fprintf(stderr,"rpc_send_blocking: %d\n",rc);
			break;
		}
	}
    fprintf(stderr,"disconnecting\n");
	rc = rpc_disconnect(c,2);
    fprintf(stderr,"rpc_disconnect: %d\n",rc);

	rpc_destroy_endpoint(e);

    }

    rpc_fini();

	return 0;
}

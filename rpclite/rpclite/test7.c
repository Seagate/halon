//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#include "rpclite.h"

#include "lib/memory.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NUM_SAMPLES 200

int rcv(rpc_item_t* it,void* ctx) {
    return 0;
}

long nsdiff(struct timespec t0,struct timespec t1) {
  return 1000*1000*1000*(t0.tv_sec-t1.tv_sec)
         + t0.tv_nsec-t1.tv_nsec;
}

int main(int argc,char** argv) {
	int rc = m0_init_wrapper();
	fprintf(stderr,"m0_init: %d\n",rc);

	rc = rpc_init("");
	fprintf(stderr,"rpc_init: %d\n",rc);

    rpc_endpoint_t* e;
	rc = rpc_listen("0@lo:12345:34:10",&(rpc_listen_callbacks_t){ .receive_callback=rcv },&e);
	fprintf(stderr,"rpc_listen: %d\n",rc);

	rpc_connection_t* c;

    int j;
    for(j=0;j<20;j+=1) {
        double cpu_time_used;
        struct timespec start, end;
        clock_gettime(CLOCK_REALTIME, &start);
        int i;
        for(i=0;i<NUM_SAMPLES;i+=1) {
    	    rpc_connection_t* c;
        	rc = rpc_connect(e,"0@lo:12345:34:10",5,&c);
    		if (rc) {
                fprintf(stderr,"rpc_connect: %d\n",rc);
                exit(1);
            }
        }
        clock_gettime(CLOCK_REALTIME, &end);
        cpu_time_used = ((double)nsdiff(end,start))/(NUM_SAMPLES*1000*1000);
        printf("[%d-%d] time per connection: %.3f ms\n",
		j*NUM_SAMPLES, (j+1)*NUM_SAMPLES-1, cpu_time_used);
    }

	printf("max connection time: %.3f ms, avg connection time: %.3f ms.\n",
		get_max_rpc_time(RPC_STAT_CONN)/(double)1000000,
		get_avg_rpc_time(RPC_STAT_CONN)/(double)1000000);
    exit(0);

    rpc_destroy_endpoint(e);
    rpc_fini();

	return 0;
}

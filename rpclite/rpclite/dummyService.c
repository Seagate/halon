/*
   Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
   License   : Apache License, Version 2.0.

   A dummy service that listens for incoming messages and performs actions
   according to message fops. For example, updating the epoch.
*/

#include "rpclite.h"
#include "ha/epoch.h"
#include "fop/fop.h"
#include "rpclite_fom.h"
#include <stdio.h>

int dummy_receive_callback(rpc_item_t* it,void* ctx)
{
  fprintf(stderr, "dummyServer: I got a message");
  m0_ha_epoch_check(&it->fop->f_item);
  return 0;
}

int main(int argc, char** argv) {
  int ret;

  if (argc != 2)
  {
    fprintf(stderr, "dummyServer: provide RPC address on command line\n");
    return 1;
  }

  ret = rpc_init("");
  if ( !ret )
    fprintf(stderr, "dummyServer: rpc_init OK\n");
  else {
    fprintf(stderr, "dummyServer: rpc_init Error %d\n", ret);
    return ret;
  }

  rpc_listen_callbacks_t cbs =
                       { .connection_callback=NULL
                       	, .disconnected_callback=NULL
                        , .receive_callback=&dummy_receive_callback
                        };

  rpc_receive_endpoint_t* re;
  rpc_listen("s1", argv[1], &cbs, &re);

  printf("Type Enter to finish...\n");

  char c;

  scanf("%c", &c);
  rpc_stop_listening(re);

  rpc_fini();
  fprintf(stderr, "dummyServer: OK\n");
  return 0;
}

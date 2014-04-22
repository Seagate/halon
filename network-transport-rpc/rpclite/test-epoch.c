/*
   Copyright : (C) 2013 Xyratex Technology Limited.
   License   : All rights reserved.

   This program tests RPC Lite with the Mero epoch API.
*/

#include "rpclite.h"

#include <pthread.h>
#include <stdio.h>

#define SERVER_ADDRESS "0@lo:12345:34:100"

void repl(rpc_connection_t* c, void* ctx, rpc_status_t st) {
  fprintf(stderr, "Reply callback: %p %d\n", ctx, st);
}

struct client_data {
  char*                   c_name;
  uint64_t                c_min;
  uint64_t                c_max;
  rpc_receive_endpoint_t* c_re;
};

void* epoch_client(void* args) {
  struct client_data* data = (struct client_data*)args;
  rpc_connection_t* c;

  rpc_connect_re(data->c_re, SERVER_ADDRESS, 8, 1, &c);

  int rc;
  uint64_t epoch = 0;
  uint64_t theirEpoch = 0;

  // test increasing epochs
  for (epoch = data->c_min; epoch <= data->c_max; epoch++) {
    rc = rpc_send_epoch_blocking(c, epoch, 2, &theirEpoch);
    fprintf(stderr, "[%s] rpc_send_epoch_blocking: %d\n", data->c_name, rc);
    if (!rc) printf("[%s] Their epoch is %d\n", data->c_name, theirEpoch);
  }

  // test decreasing epochs
  for (epoch = data->c_max; epoch >= data->c_min; epoch--) {
    rc = rpc_send_epoch_blocking(c, epoch, 2, &theirEpoch);
    fprintf(stderr, "[%s] rpc_send_epoch_blocking: %d\n", data->c_name, rc);
    if (!rc) printf("[%s] Their epoch is %d\n", data->c_name, theirEpoch);
  }

  // test whether rpclite send works well afterwards
  struct iovec segments[] = { { .iov_base = "segment 1", .iov_len = 10 },
                              { .iov_base = "segment 2", .iov_len = 10 } };

  rc = rpc_send_blocking(c, segments, 2, 2);
  fprintf(stderr, "[%s] rpc_send_blocking: %d\n", data->c_name, rc);

  rc = rpc_send(c, segments, 2, repl, (void*)5, 2);
  fprintf(stderr, "[%s] rpc_send: %d\n", data->c_name, rc);

  rpc_disconnect(c, 1);

  return NULL;
}

int main(int argc, char** argv) {
  int ret;

  ret = rpc_init("");
  if ( !ret )
    fprintf(stderr, "rpc_init: OK\n");
  else {
    fprintf(stderr, "rpc_init: Error %d\n", ret);
    return 2;
  }

  rpc_receive_endpoint_t* re;
  rpc_listen("s1", SERVER_ADDRESS, NULL, &re);

  pthread_t client1;
  pthread_t client2;
  struct client_data client1_data = {
    .c_name = "Client 1",
    .c_min = 12,
    .c_max = 15,
    .c_re = re
  };

  struct client_data client2_data = {
    .c_name = "Client 2",
    .c_min = 13,
    .c_max = 16,
    .c_re = re
  };

  pthread_create(&client1, NULL, &epoch_client, &client1_data);
  pthread_create(&client2, NULL, &epoch_client, &client2_data);

  pthread_join(client1, NULL);
  pthread_join(client2, NULL);

  rpc_stop_listening(re);

  rpc_fini();
  fprintf(stderr, "Test epoch: OK\n");
  return 0;
}

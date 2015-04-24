#include "hastate.h"
#include "rpclite.h"
#include "conf/obj.h"

int rcv(rpc_item_t* it,void* ctx) {
    fprintf(stderr,"\nrcv callback\n");
    return 0;
}

void show_nvec(struct m0_ha_nvec *nvec) {
     int i;
     if (nvec == NULL) {
          fprintf(stderr, "nvec is NULL\n");
          return;
     }
     for (i = 0; i < nvec->nv_nr; i++) {
          fprintf(stderr, "nvec[i]->no_id = %d:%d\n",
                  nvec->nv_note[i].no_id.f_container,
                  nvec->nv_note[i].no_id.f_key);
          fprintf(stderr, "nvec[i]->no_state = %d\n",
                  nvec->nv_note[i].no_state);
     }
}

void hs_get(struct m0_ha_nvec *note) {
     fprintf(stderr, "\nha_state_get callback\n");
     show_nvec(note);
}

int hs_set(struct m0_ha_nvec *note) {
     fprintf(stderr, "\nha_state_set callback\n");
     show_nvec(note);
     return 0;
}

int main(int argc,char **argv) {
    if (argc<3) {
        fprintf(stderr,"%s local_address remote_address",argv[0]);
        return -1;
    }

    int rc;
    ha_state_callbacks_t cb = {
         .ha_state_get = hs_get,
         .ha_state_set = hs_set
    };

    rc = rpc_init("");
    printf("rpc_init: %d\n",rc);
    rc = ha_state_init(&cb);
    printf("ha_state_init: %d\n",rc);

    rpc_receive_endpoint_t* re;

    rc = rpc_listen("s1",argv[1],&(rpc_listen_callbacks_t){ .receive_callback=rcv },&re);
    fprintf(stderr,"rpc_listen: %d\n",rc);

    struct m0_ha_note n = { M0_FID_TINIT('n',1,1), M0_NC_ONLINE };
    struct m0_ha_nvec note = { 1, &n };

    rc = ha_state_notify(re,argv[2],&note,3);
    fprintf(stderr,"ha_state_notify: %d\n",rc);

    rpc_stop_listening(re);

    ha_state_fini();
    rpc_fini();
    printf("Done.\n");
    return 0;
}

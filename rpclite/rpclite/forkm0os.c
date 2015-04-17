#include "forkm0os.h"
#include "lib/thread.h"

static void worker(HsFunPtr action) {
  action();
  hs_free_fun_ptr(action);
}

/// Runs the given action in an M0_THREAD
int forkM0OS_createThread (struct m0_thread* t, HsFunPtr action) {
    M0_SET0(t);
    return M0_THREAD_INIT(t, HsFunPtr, NULL, &worker, action, "forkM0OS");
}

int forkM0OS_joinThread (struct m0_thread* t) {
    int rc = m0_thread_join(t);
    if (!rc) m0_thread_fini(t);
    return rc;
}

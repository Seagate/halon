/* This file implement basic paxos in promela.

   Definitions of proposers and acceptors are taken from the Haskell
   files which implement them.

   Type
   make verify
   to verify this program.
*/

/* The amount of acceptors. There are as many proposers as acceptors. */
#define PROCS 2
/* The amount of decrees that each acceptor can remember.
*/
#define ACKS_LEN 2
/* The amount of proposals that each proposer does before terminating.
   On each attempt, each proposer will be given a random decree within
   the range [0..(ACKS_LEN-1)] and a random value.
*/
#define AMOUNT_OF_PROPOSALS 2

/* 1 iff connections can fail. TODO: Need to rethink how to do this. */
#define WITH_FAILURES 0

/* 1 iff garbage collection is simulated. */
#define WITH_GARBAGE_COLLECTION 0

/* We define send and receive primitives to approximate the semantics of
   Cloud Haskell primitives.

   On the implementation there is a single channel on which messages are
   tagged with their destination pids. When receiving, the processes match
   only the messages tagged with their pids.
*/
#if WITH_FAILURES
#define send(pid,type,msg)                                                    \
  if                                                                          \
  :: !failed[self].a[pid] ->                                                  \
       if                                                                     \
       :: atomic { nfull(mbox) -> mbox!pid,type,msg }                         \
       :: atomic { !garbageCollect -> garbageCollect = 1 }; mbox!pid,type,msg \
       fi                                                                     \
  :: !failed[self].a[pid] -> failed[self].a[pid] = 1                          \
  :: failed[self].a[pid] -> skip                                              \
  fi
#else
#if WITH_GARBAGE_COLLECTION
#define send(pid,type,msg)                                               \
  if                                                                     \
  :: atomic { nfull(mbox) -> mbox!pid,type,msg }                         \
  :: atomic { !garbageCollect -> garbageCollect = 1 }; mbox!pid,type,msg \
  fi
#else
#define send(pid,type,msg)    mbox!pid,type,msg
#endif
#endif

#define receive(self,type,msg) mbox??eval(self),type,msg
/* Like receive but does not remove the message from the channel */
#define poll(self,type,msg) mbox??[eval(self),type,msg]

typedef Ballot {
  bit bottom;
  short n;
  pid bpid
}

/* A set of Ack messages. There is at most one Ack per decree.
   The acks are indexed by decree number.
*/
typedef Acks {
  bit   bottoms[ACKS_LEN];
  short ns[ACKS_LEN];
  byte   bpids[ACKS_LEN];

  pid      apids[ACKS_LEN];
  byte     axs[ACKS_LEN];

  bit filled[ACKS_LEN]; /* filled[decree] == 1 iff there is an Ack in the set
                           for the decree.
                         */
}

typedef Msg {
  Ballot b;
  short mpid; /* pid of the process where the message originates */
  byte x;  /* proposed value */
  byte d;  /* decree */
  bit has_decree; /* does this message carry a decree? */
}

chan mbox = [32] of { byte, mtype, Msg }

#if WITH_FAILURES
typedef bit_array {
  bit a[PROCS*2] = 0
}

bit_array failed[2*PROCS] = 0;
#endif

mtype = { PREPARE, PROMISE, NACK, ACK, SYN }

inline ballot_ini(b) { b.bottom = 1; }

/* Copies a ballot. */
inline ballotcpy(p_b0,p_b1) {
  p_b0.bottom = p_b1.bottom;
  p_b0.n = p_b1.n;
  p_b0.bpid = p_b1.bpid
}

/* Compares two ballots yielding -1, 0 or 1 for the cases where the first
   value is less than, equal or greater than the second value respectively.
 */
#define ballotcmp_(bottom0,n0,bpid0,bottom1,n1,bpid1) \
  (bottom0                                          \
     -> (bottom1 -> 0 : -1)                         \
      : (bottom1 -> 1 :                             \
          (n0 < n1                                  \
             -> -1                                  \
              : (n0 > n1                            \
                   -> 1                             \
                   : (bpid0 < bpid1                 \
                        -> -1                       \
                        : (bpid0 == bpid1 -> 0 : 1) \
                     )                              \
                )                                   \
           )                                        \
        )                                           \
  )

/* Compares two ballots yielding -1, 0 or 1 for the cases where the first
   value is less than, equal or greater than the second value respectively.
 */
#define ballotcmp(b0,b1) ballotcmp_(b0.bottom,b0.n,b0.bpid,b1.bottom,b1.n,b1.bpid)

/* Removes all decrees from a set of acks. */
inline clear_acks(p_acks) {
  byte clear_i;
  do
  :: clear_i<ACKS_LEN ->
       p_acks.filled[clear_i] = 0;
       clear_i++
  :: else -> break
  od
}

#define assign_ack(a0,i,v0,v1,v2,v3,v4) \
  a0.bottoms[i] = v0; \
  a0.ns[i]      = v1; \
  a0.bpids[i]   = v2; \
  a0.apids[i] = v3;   \
  a0.axs[i]   = v4;

/* Adds an Ack message to a set if the ballot in the message is high enough. */
inline addack(a0,msg) {
  /* Update only if the ballot number is higher or the decree is not present. */
  if
  :: msg.has_decree &&
     (!a0.filled[msg.d]
      || ballotcmp_(a0.bottoms[msg.d],a0.ns[msg.d],a0.bpids[msg.d]
                   ,msg.b.bottom,msg.b.n,msg.b.bpid) < 0
     ) ->

       assign_ack( a0,msg.d
            , msg.b.bottom
            , msg.b.n
            , msg.b.bpid
            , msg.mpid
            , msg.x
            );
       a0.filled[msg.d] = 1;
  :: else -> skip
  fi
}

/* Garbage collection of messages from channels

  When a channel is full, either messages are discarded or the sender is blocked.

  For simulation purposes we clean the channel from messages that will be never
  read when the channel fills. To recognize abandoned messages we maintain a list
  of active processes. If a message is not tagged with an active pid, it is removed.
*/
#if WITH_GARBAGE_COLLECTION
short activePids[3*PROCS];
byte activePidLen = 0;
#endif
short nextActivePid = 0;

/* isPidActive(i,pid) writes in i the index of pid in the array of active pids if it
  is active. Otherwise it writes activePidLen on i.
*/
inline isPidActive(p_i,p_pid) {
  d_step {
    p_i = 0;
    do
    :: p_i < activePidLen && p_pid != activePids[p_i] -> p_i++
    :: else -> break
    od
  }
}

/* Finds an available pid and makes it active. */
#if WITH_GARBAGE_COLLECTION
inline generatePid(p_child) {
  d_step {
    p_child = nextActivePid;
    nextActivePid++;
    byte gen_i;

    do
    :: isPidActive(gen_i,p_child);
       if
       :: gen_i == activePidLen -> break
       :: else -> p_child++
       fi
    od;
    activePids[activePidLen] = p_child;
    activePidLen++;
  }
}
#else
inline generatePid(p_child) {
  d_step {
    p_child = nextActivePid;
    nextActivePid++;
  }
}
#endif

/* Reports a process as no longer active. */
#if WITH_GARBAGE_COLLECTION
inline disposePid(p_pid) {
  d_step {
    byte disposePid_i;
    isPidActive(disposePid_i,p_pid);
    if
    :: disposePid_i < activePidLen ->
         activePids[disposePid_i] = activePids[activePidLen-1];
         activePidLen--;
    :: else -> skip
    fi
  }
}
#else
inline disposePid(p_pid) { skip }
#endif

/* Whether garbageCollection should happen. The Garbaga Collector process
   waits on this variable so it collects garbage when it is set to 1.
*/
bit garbageCollect = 0;

typedef byte_arr {
  byte b[PROCS] = 255;
}

/* A storage for the values chosen by each proposer for each decree. */
byte_arr pxs[ACKS_LEN];

/** Checks that different proposers agree on the values for the decrees. */
inline checkAgreement() {
  byte ca_i=0;
  do
  :: ca_i < ACKS_LEN ->
       byte ca_j = 0;
       do
       :: ca_j < PROCS ->
            if
            :: pxs[ca_i].b[ca_j] < 255 ->
                 byte ca_k=ca_j+1;
                 do
                 :: ca_k < PROCS ->
                      assert(pxs[ca_i].b[ca_k] == 255
                             || pxs[ca_i].b[ca_j] == pxs[ca_i].b[ca_k]
                            );
                      ca_k++
                 :: else -> break
                 od
            :: else -> skip
            fi;
            ca_j++
       :: else -> break
       od;
       ca_i++;
  :: else -> break
  od
}

/* This is the file generated from extracting promela code from Haskell source
   files.
*/
#include "extracted.pml"

/* The garbage collector process -- it pops and pushes all messages in the
   channel, discarding those that do not belong to active processes.
*/
#if WITH_GARBAGE_COLLECTION
active proctype GarbageCollector() {
  short p;
  mtype t;
  Msg msg;
  atomic {
    do
    :: garbageCollect && nempty(mbox) ->
         byte i= len(mbox);
         garbageCollect = 0;
         do
         :: i > 0 ->
              mbox?p,t,msg;
              byte j;
              isPidActive(j,p);
              if
              :: j != activePidLen -> mbox!p,t,msg;
              :: else -> garbageCollect = 1;
              fi;
              i--
         :: else -> break
         od;
    od
  }
}
#endif

init {
  atomic {
   byte i = 0;
   byte p;
   do
   :: i < PROCS ->
        generatePid(p)
        run Acceptor(p);
        i++
   :: i == PROCS -> break
   od;
   i = 0;
   do
   :: i < PROCS ->
        generatePid(p);
        assert(p == i + PROCS);
        i++
   :: i == PROCS -> break
   od;
   i = 0;
   do
   :: i < PROCS ->
        run Proposer(i+PROCS);
        i++
   :: i == PROCS -> break
   od
  }
}

/* Limits state search to those states where the queue is not filled and no
   more than 3000 pids are created.
*/
never {
  do
  :: nextActivePid < 10 && nfull(mbox)
  od
}

/*
ltl safety_proposers_agree {
  ([]nextActivePid<1000) ->
  []( (Proposer[0]@value_accepted
       && Proposer[0]@value_accepted
       && Proposer[1]@value_accepted
       && Proposer[2]@value_accepted
       && Proposer[3]@value_accepted
       && Proposer[4]@value_accepted
       && Proposer[0]:d == Proposer[1]:d
       && Proposer[0]:d == Proposer[2]:d
       && Proposer[0]:d == Proposer[3]:d
       && Proposer[0]:d == Proposer[4]:d
      )
      ->
       (Proposer[0]:x1 == Proposer[1]:x1
        && Proposer[0]:x1 == Proposer[2]:x1
        && Proposer[0]:x1 == Proposer[3]:x1
        && Proposer[0]:x1 == Proposer[4]:x1
       )
    )
}*/

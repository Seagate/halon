/* 
 * Copyright: (C) 2015 Seagate Technology Limited.
 * 
 * This is a model of leader election in recovery supervisors.
 *
 * TODO: Model clock drift between RSs.
 * TODO: Model delays when killing the RC.
 * TODO: Verify that a leader is eventually elected.
 * TODO: Test changing the lease period online.
 */

// Number of recovery supervisors
#define NRS 3

// For how long should we let the clock run? Units are artificial ticks.
#define CLOCK_BOUND 9

#define INITIAL_LEASE_PERIOD 3

// How much larger is the polling period than the lease period?
#define POLLING_PERIOD_OFFSET 1

// Model of the replicated group
//
// This is just a single process which receives requests to update the
// replicated state of recovery supervisors.
//
// Each request carries the lease count, if it is the same leaseCount as
// observed last time, then the leader is updated.

// Channel for sending requests to the replicated group.
//
// Each request carries the pid of the requester and the lease count to use for
// comparison.
chan rgchan = [0] of { byte, byte };

// The channels used to receive replies from the replicated group.
chan mb[NRS] = [1] of { byte, byte, byte };

proctype RG () {
  byte leader = NRS;
  byte leaseCount = 0;
  byte leasePeriod = INITIAL_LEASE_PERIOD;
  byte oldLeaseCount;
  byte rspid;

  assert(leasePeriod > 0);

end_rg:
  do
  :: rgchan ? rspid, oldLeaseCount ->
     d_step {
     if
     :: oldLeaseCount == leaseCount ->
        leaseCount = leaseCount + 1;
        leader = rspid;
     :: else -> skip;
     fi;
     mb[rspid] ! leader, leaseCount, leasePeriod;
     }
  od
}

// The leases of the recovery supervisors.
//
// We represent here the lease as the amount of ticks remaining until it
// expires.
//
// One invariant we check is that at most one lease is greater than 0.
byte lease[NRS] = 0;

inline assertAtMostOneLeader() {
  d_step {
  byte i = 0;
  byte count = 0;
  i = 0;
  do
  :: i == NRS ->
     break
  :: else ->
    if
    :: lease[i] > 0 ->
       count = count + 1;
    :: else ->
       skip
    fi;
    i = i + 1;
  od;
  assert(count <= 1)
  }
}

// All RSs use the same clock.
byte clock = 0;

// The polling timeout of each RS expressed as the amount of ticks remaining.
byte pollingTimeout[NRS] = 0;

proctype Clock() {
  byte i;
  do
  :: clock >= CLOCK_BOUND ->
     break
  :: else ->
     d_step {
     clock = clock + 1;
     i = 0;
     do
     :: i == NRS ->
        break
     :: else ->
        if
        :: lease[i] > 0 ->
           lease[i] = lease[i] - 1;
        :: else -> skip
        fi;
        if
        :: pollingTimeout[i] > 0 ->
           pollingTimeout[i] = pollingTimeout[i] - 1;
        :: else -> skip
        fi;
        i = i + 1
     od
     }
  od
}

proctype RS (byte rspid) {
  // The time at which a lease started.
  byte t0;
  // The replicated state.
  byte leader;
  byte leaseCount = 0;
  byte leasePeriod;

  assert(rspid < NRS);

  do
  // End of the execution
  :: clock >= CLOCK_BOUND ->
     break

  // Ready to compete for the lease.
  :: 0 < lease[rspid] && lease[rspid] <= rspid / 3
     || lease[rspid] == 0 && pollingTimeout[rspid] == 0 ->
     t0 = clock;
     rgchan ! rspid, leaseCount;
     
     d_step {
     mb[rspid] ? leader, leaseCount, leasePeriod;
     if 
     :: clock - t0 < leasePeriod && rspid == leader ->
        lease[rspid] = leasePeriod - (clock - t0);
        assertAtMostOneLeader();
     :: else ->
        assert(lease[rspid] == 0);
        pollingTimeout[rspid] = leasePeriod + POLLING_PERIOD_OFFSET;
     fi
     }
  od
}

init {
  assert (NRS > 0);
  assert (NRS <= 255);
  byte i = 0;
  atomic {
  run Clock();
  run RG();
  do
  :: i == NRS ->
     break
  :: else ->
    run RS(i);
    i = i + 1;
  od;
  }
}

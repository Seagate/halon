/* 
 * Copyright: (C) 2015 Seagate Technology Limited.
 * 
 * This is a model of timer that is used in election algorithm.
 *
 */

//===============================================================================
// Constants
//===============================================================================
#define false 0
#define true  1

#define NOTHING    0
#define JUST_FALSE 1
#define JUST_TRUE  2

// Callback event happened
byte fired   = 0;
// Timeout had happened
byte timeout_happened = 0;
// Callback process was killed
byte callback_killed = 0;
// Return result of the cancel call
byte result  = 0;

// cancelled variable
byte mvar_mv_empty = 0;
byte mvar_mv_value = 0;

// done variable
byte mvar_done_empty = 1;
chan killchan = [0] of {byte};

//===============================================================================
// Helpers
//===============================================================================
// Here we define a helper functions, it's possible to implement locking in
// simpler terms however we choose MVar-like semantics to be closer to haskell
// code.

// Take MVar model.
#define TAKE_MVAR(mvar_empty, mvar_value, result) \
  atomic { \
      mvar_empty == 0; \
      mvar_empty = 1; result = mvar_value; \
  }

// Take MVar in presence of exceptions, in case if asynchonous exception
// arrived and if jump to the label.
#define TAKE_MVAR_EXC(mvar_empty, mvar_value, killed, lbl, result) \
  do \
  :: 1 -> atomic { \
      if \
      :: mvar_empty == 0 -> \
         mvar_empty = 1; result = mvar_value; break \
      :: killed == 1 -> goto lbl \
      :: else -> skip \
      fi \
      } \
  od

// Activization of timeout
proctype Timeout() {
  timeout_happened = 1;
}

// A way to postphone kill call
active proctype Killer() {
  killchan ? 1;
  callback_killed = 1;
}

proctype Callback() {
  byte mvar_value = 0;
  do
  :: timeout_happened == 1 -> break;
  :: callback_killed == 1  -> goto done;
  :: else -> skip;
  od;
  TAKE_MVAR_EXC(mvar_mv_empty, mvar_mv_value, callback_killed, done, mvar_value);
  if 
  :: mvar_value == NOTHING ->
     if
     :: callback_killed == 1 -> goto done
     :: else -> fired = fired + 1;
     fi;
     // putMVar with assumption that it always empty and process can't be killed
     atomic {
        assert(mvar_mv_empty==1);
        assert(callback_killed == 0);
        mvar_mv_empty = 0;
        mvar_mv_value = JUST_FALSE
     }
  :: else
     atomic {
       assert(mvar_mv_empty == 1);
       assert(callback_killed == 0);
       mvar_mv_empty = 0;
       mvar_mv_value = mvar_value
     }
  fi;
done:
  mvar_done_empty = 0
}

proctype Cancel() {
  byte mvar_value = 0;
  TAKE_MVAR(mvar_mv_empty, mvar_mv_value, mvar_value);
  if 
  :: mvar_mv_value == 0 ->
     if 
     :: timeout_happened == 1 ->
        atomic {
          assert(mvar_mv_empty == 1);
          mvar_mv_empty = 0;
          mvar_mv_value = NOTHING;
        }
        (mvar_done_empty == 0);
        assert(result == NOTHING || result == JUST_FALSE);
        result = JUST_FALSE;
    :: else ->
        killchan ! 1;
        (mvar_done_empty == 0);
        atomic {
          assert(mvar_mv_empty == 1);
          mvar_mv_empty = 0;
          mvar_mv_value = JUST_TRUE;
        }
        assert(result == NOTHING || result == JUST_TRUE);
        result = JUST_TRUE;
    fi
  :: else ->
    atomic {
      assert(mvar_mv_empty == 1);
      mvar_mv_empty = 0;
      mvar_mv_value = mvar_value;
    }
    assert(result == NOTHING || result == mvar_value);
    result = mvar_value;
  fi;
  assert(result != NOTHING);
}

active proctype monitor() {
  assert (fired <= 1);
  assert ((result == JUST_TRUE && fired == 0) || (result == JUST_FALSE && fired == 1) || result == 0);
}

init {
  atomic {
    run Callback();
    run Cancel();
    run Timeout();
    run Cancel();
  }
}

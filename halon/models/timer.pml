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
byte callback_is_dead = 0;

// Return result of the cancel call
byte timer_result  = 0;

byte doneref = NOTHING;

chan killchan = [0] of {byte};
// channel to receive monitor value
chan callback_monitor = [0] of {byte};



// Activization of timeout
proctype Timeout() {
  timeout_happened = 1;
}

// A way to postphone kill call
active proctype Killer() {
  end: killchan ? 1;
  callback_killed = 1;
}

proctype Callback() {
  byte result = NOTHING;
  // wait required timeout (process could be killed here)
  do
  :: 1 -> atomic {
     if
     :: timeout_happened -> break;
     :: callback_killed  -> goto done;
     :: else -> skip;
     fi
     }
  od;
  // modify shared variable
  atomic {
    if
    :: doneref == NOTHING ->
       result = doneref;
       doneref = JUST_FALSE;
    :: else ->
       result = doneref;
    fi;
  }
  // run action
  if
  :: callback_killed -> goto done;
  :: result == NOTHING ->
     fired = fired + 1;
  :: else -> skip
  fi;
done:
    callback_is_dead = 1;
}

proctype CallbackMonitor(chan mon) {
  callback_is_dead;
  mon ! 1;
}

proctype Cancel() {
  byte done = 0;
  byte result = 0;
  chan mon = [1] of {byte}
  atomic {
    if
    :: doneref == NOTHING && ! timeout_happened ->
       done = doneref;
       doneref = JUST_TRUE;
    :: else ->
       done = doneref;
    fi
  }

  if
  :: ! timeout_happened && done == NOTHING ->
    atomic {
      killchan ! 1;
      result = JUST_TRUE;
    }
  :: else -> result = done;
  fi;

  // monitor death
  run CallbackMonitor(mon);
  mon ? 1;
  timer_result = result;
}

active proctype monitor() {
    if
     :: timeout ->
        assert (fired <= 1);
        assert (  (timer_result == JUST_TRUE  && fired == 0)
               || (timer_result == JUST_FALSE && fired == 1)
               || timer_result == 0);
    fi;
}

init {
  atomic {
    run Callback();
    run Cancel();
    run Timeout();
    run Cancel();
  }
}

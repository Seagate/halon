# Notes for the Sprint 2 demo

## Introduction

This demo shows the following features:
* Simultaneous event reporting
* Explicit event routes
* Path compression

The halon source code is tagged with the demo-sprint2 tag.
This is the only version that will allow you to run the demo as described
below.

## Script

* Start four node agents.
* Start replicas in three of them.
* Wait for a leader to be elected.

* Have the other NA produce an event.
* Wait for the NA to receive an acknowledgement.
* Comment on the event route which is printed 

If the event goes directly to the RC node proceed to simulate a failure.
Otherwise, explain path compression by producing another event and
observing how the RC node is contacted this time.

When the printed route changes, comment on it again.

* Simulate a network failure that isolates NA from RC.
* Simulate another network failure that isolates another replica from NA
  to avoid competition during staggering.
* Have the NA produce an event. It should first try the RC node, then
  the other nodes after the staggering delay. The reply from one of them
  will arrive first with the pid of the collocated EQ.
* Have the NA produce an event. It should first try the previously most
  responsive node, which should reply with the pid of the collocated
  EQ. It also should try to contact the RC node.

* Stop simulating the network failure.
* Have the NA produce an event. It should first try the previously most
  responsive node, which should reply with the pid of the collocated EQ.
  It also should try to contact the RC node. Now, both nodes reply.

* Have the NA produce one more event. It should try to contact the RC node.
* Kill the RC node.
* Have the NA produce an event and show the overlap of staggering and
  timeouts in the NA.


## Useful commands

Create a droplet in digital ocean and provision it for a halon demo.

Watch out that the commands below build the master branch in the droplet.
Because of a bug in the build system you will have to delete the halon
and mero-halon packages from the sandbox and delete-sources of the
halon package before rebuilding the demo-sprint2 branch. Or otherwise,
delete the sandbox and rebuild all dependencies again.

```
export DO_CLIENT_ID=...
export DO_API_KEY=...
ansible-playbook playbooks/new_droplet.yml -i do/dohosts -e name=halon-demo -v
ansible-playbook playbooks/provision-halon.yml -i do/dohosts -e "hosts=halon-demo"
```

Clean up state from previous executions.

```
rm -rf demo-*
```

Start a node agent in various ports and define folders for each one to
place files into. The script `script/beautify` replaces addresses with
more readable labels.

```
export MERO_ROOT=--
HA_RPC_FOLDER=demo-r1 scripts/halon node-agent | scripts/beautify
HA_RPC_FOLDER=demo-r2 NAPORT=8083 LAPORT=8084 scripts/halon node-agent \
  | scripts/beautify
HA_RPC_FOLDER=demo-r3 NAPORT=8085 LAPORT=8086 scripts/halon node-agent \
  | scripts/beautify
HA_RPC_FOLDER=demo-na1 NAPORT=8087 LAPORT=8088 scripts/halon node-agent \
  | scripts/beautify
```

Start the tracking station.

```
HA_RPC_FOLDER=demo-station scripts/halon station | scripts/beautify
```

Have a node produce an event.

```
touch demo-na1/dummy-striping-error
```

Have an event queue drop events from cohorts. The number after
`event-queue.pid` can be figured out from a file with a similar name
which is located in the same folder.

```
touch demo-r2/event-queue.pid1270118083010.fail
```

Stop an event queue from dropping events.

```
rm demo-r2/event-queue.pid1270118083010.fail
```

Starting a tmux session with either mosh or ssh.

```
mosh dev@<some ip> -- tmux -S /tmp/tmux-pp
ssh dev@<some ip> -t -- tmux -S /tmp/tmux-pp
```

Joining a tmux session with either mosh or ssh.

```
mosh dev@<some ip> -- tmux -S /tmp/tmux-pp attach
ssh dev@<some ip> -t -- tmux -S /tmp/tmux-pp attach
```

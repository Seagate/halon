# RFC: Rolling Updates

## Introduction

For version 1.1, we must support rolling (node-by-node) updates of the system.
This document describes how this should be managed in the tracking station.

## Constraints

- The system must continue to operate normally at all stages of the update
  process.

- A recovery supervisor node running version x may not spawn a recovery
  coordinator if the replicated log contains entries from a future version,
  unless explicit "downgrade" has been performed.

## Notes

We fairly freely conflate the roles of replica/RS and leader/RC in this PR. This
is because they are currently co-located, and so constraints which apply to the
RC can be seen to apply to the replica leader, for example.

## Design

We rely on the fact that replicas, while responsible for recording decrees
passed by the leader, do not need to inspect the contents of these, and that
- assuming no pathological failures - their inability to do so should not
affect the availability of the system.

Consider an upgrade from version A of halon to version B. We propose that the
upgrade would proceed in four stages:

1. In the first stage, there are < n/2 nodes running version B. The leader
   should continue to be hosted on a node running version A. Nodes running
   version B should record decrees passed by version A, but may not become the
   leader.
1. When a majority of nodes have been updated to version B, election rules
   should guarantee the leadership passes to a node running version B. Its
   first action is to record a special decree marking that version B is now
   the latest running version.
1. In the third stage, there are > n/2 nodes running version B. Nodes running
   version A should record decrees passed by version A, but may not become the
   leader.
1. In the final stage, all nodes are running version B and may become leader.

Three changes are required to implement this proposal:

1. Nodes must now broadcast their version information when joining a quorum.
1. It must be possible to record the latest version used in the replicate log.
1. Election rules must be changed to ensure the correct node becomes RC.

### Selecting a leader (or RC)

Nodes should consider their eligibility to be leader according to the following:

1. Are they running a version greater than the latest version recorded in the
   replicated log?
2. If so, are they running the same version as the majority of nodes in the
   cluster. In the event of a tie, any version which has equal majority should
   be considered.

Nodes which do not satisfy these criteria should not attempt to become the
leader, even if they previously held the role. This should be checked on lease
renewal.

## See also

See RFC019 for details of the update process to the RG on individual nodes,
and RFC021 for details of how communication with services should be maintained
during the rolling update.

There will be an as-yet unwritten RFC to cover downgrades.

# RFC: Supervision

## Introduction

Halon includes a variety of tasks that must be kept available.  In
order to ensure avaliability, these tasks should each be supervised by
a supervisor process that is capable of helping them recover from
errors, often by simply restarting them.  This document attempts to
define a hierarchy of supervisors that ensures that each service has a
supervisor managing it.

## Purpose

## Constraints

+ A supervisor should be responsible for managing a relatively small
  number of services, to minimize potential damage from a failed
  supervisor.

+ Supervisors need to know the state of the nodes they manage.

+ For efficiency, events that can be handled locally should be handled
  locally.


## Description

The system described here is an interaction between two different
types of process: a ‘health monitor’, which is responsible for
generating events about service failures, and a ‘supervisor’, which is
responsible for handling them.  Each supervisor in the hierarchy
should be paired with a health monitor.

Supervisors and health monitors can themselves be processes, and are
therefore capable of being supervised themselves in much the same way.

### Structure

The hierarchy is a tree.  Each node of the tree is responsible for the
supervision of its immediate children; however, this may require
consideration of events generated further down the tree.

#### Recovery supervisor
The root of the hierarchy is the recovery supervisor.  The recovery
supervisor is responsible for launching and supervising recovery
coordinator nodes.

#### Recovery coordinator
The recovery coordinator is a distributed machine that is responsible
for handling events that require cluster-spanning information.
Particularly, it makes sense to have the recovery coordinator
supervise the node supervisors and health monitors.

#### Node supervisor
Each node should have a node supervisor/monitor pair.  The node's
monitor will generate service death events, which will be handled by
the local supervisor; however, the recovery coordinator will also
listen to them and log them as per functional requirement
[fr.logging], and may decide that there is a larger problem that
requires restarting or abandoning the supervisor or the node in
general.

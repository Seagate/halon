Architecture documentation
==========================

This :abbr:`SAD (software documentation architecture)` provides an
overview of the architecture of Halon, a software solution for
high-availability of large clusters and real-time automated recovery.
This set of documents is intended as a reference for architecture,
a starting point for :abbr:`HLD (high-level design)` documents
and :abbr:`DLD (detailed-level design)` documents, and to be inspected
by architects and peer designers for the presence of any defects.

.. Note::

   This document forms a part of the Halon architecture documentation.
   This documentation follows a standard format published by the SEI,
   that of the “Views and Beyond” methodology [1]_.

About this document
-------------------

Following the "Views and Beyond" methodology [1]_, this documentation
is structured as a set of :term:`views`, each documenting the software
architecture from a different :term:`viewpoint`.

The SAD has the following structure:

- :ref:`arch-background` explains why the architecture is what it is.
  It provides a system overview, establishing the context and goals
  for the development. It describes the background and rationale for
  the software architecture. It explains the constraints and
  influences that led to the current architecture, and it describes
  the major architectural approaches that have been utilized in the
  architecture.
- :ref:`views` and :ref:`arch-views-mapping` specify the software
  architecture. Views specify elements of software and the
  relationships between them.
- The :ref:`arch-directory` includes an index of architectural
  elements and relations indicating where each one is defined and used
  in this SAD. The section also includes a :ref:`arch-glossary`
  and :ref:`arch-acronyms`.

.. _arch-background:

Architecture background
-----------------------

Problem background
~~~~~~~~~~~~~~~~~~

System overview
+++++++++++++++

Halon is a :abbr:`HAMS (high-availability management system)`. This
system is meant to ensure that deployments of sets of services and
applications in a cluster are highly available to users. Meaning that
(distributed) applications are able to continuously make progress, and
services can continuously service requests from users and their
applications.

A distributed application is highly available when an agreed procedure
is followed in the case of failures, in such a way that these failures
ultimately cause as little disruption as possible to users of that
application. This agreed procedure is called :term:`recovery`.
Examples of actions that a recovery procedure might include are:

- restarting failed processes on the same node they were running on,
- failing over the processes hosted by a failed node to another node,
- taking out failed disks from storage pools, and
- notifying all other nodes to take appropriate corrective measures in
  response to a failure.

.. _arch-goals-and-context:

Goals and context
+++++++++++++++++

In the past few years, the United States, the European Union, and
Japan have each moved aggressively to develop their own plans for
achieving exascale computing in the next decade. Exascale means
building and managing clusters whose compute power is measure in
exaflops, and whose storage capacity is measured in exabytes. But
extra power and capacity translates into a higher number of hardware
components as the industry starts hitting a number of vertical scaling
limits (such as Moore's law for CPU's, or Kryder's law for storage
density). Limited vertical scaling means that much of the extra
compute power and storage capacity are achieved by scaling systems
horizontally: adding more and more diverse compute units, more and
more diverse storage technologies.

The increasing number of components in a system has a dramatic effect
on the system: the probability that nothing goes wrong during any unit
of time decays exponentially with respect to the number of components
in the system. And as the number of components in the system double,
the overall :abbr:`MTBF (mean time between failures)` halves.

Each time a failure happens, some recovery procedure must be
undertaken. Recovery times can be long, but typically they can be
significantly reduced by introducing redundancy into the system. For
example, Seagate's ClusterStor division delivers systems that
integrate the Lustre open-source distributed filesystem running on
server pairs. ClusterStor systems use dual-ported drives that provide
a data path to each server in an embedded server pair. If one of the
two servers in a pair fail, ownership of the drives can be failed over
to the other server in a matter of minutes or seconds.

This high-availability strategy works well for resources that can be
recovered locally, without modifying global cluster state, as is the
case above with Lustre :abbr:`OSS (object storage server)` pairs.
However, in this scheme recovery times are still too long and recovery
only happens on the basis of (partial) local information, or costly
timeouts that don't scale, rather than leveraging a global view of the
cluster for more efficient failover strategies. Fundamentally, current
systems are designed with the assumption that failures are rare
events, in which case time-consuming recovery/reconstruction phases
are not much of a problem. This assumption falls apart in an exascale
system, where the number of hardware components alone imply that
failures are the norm not the exception. Exascale systems must assume
a mode of operation where they are constantly in a "degraded" state,
constantly undergoing (often concurrent) recovery procedures.

Disk failures
"""""""""""""

Current disk drives have a mean time to failure (MTTF) rating
of :math:`10^6` to :math:`1.5 \times 10^6` hours, though Schroeder and
Gibson [2]_ report that in high-performance computing sites and
internet services sites, typical disk replacement rates exceed the
vendor supplied rating by 13%, with 2 to 5 times the rating being
common and that up to one order of magnitude higher replacement rates
have been observed.

We wish to scale all the way up to clusters storing 10EB. This would imply
the presence of up to approximately 1M disks. For a cluster with this many
disks, the data of Schroeder and Gibson suggests that disk failures are
normally expected to happen 1 times/hour on average when the observed MTTF
is close to that of the vendor supplied rating. If the observed MTTF happens
to diverge significantly, this would still only imply an expected failure
rate of about 10 times/hour, i.e. from once every 6 minutes to once every
hour. Assuming disk failure is a Poisson process, this means that we can
expect no more than 27 failures/hour 99.999% of the time, or at most 3
failures/minute with the same confidence interval. This means that a
recovery time of up to 20 seconds on average is acceptable (from
a performance standpoint, but not necessarily for availability).

One must be cautious to acknowledge that hardware failures are not
completely uncorrelated - indeed the correlation observed by Schroeder and
Gibson between the number of failures in a given time period and that in the
previous time period is very high. Such high correlation means that a very
rapid succession of failures is even more likely than what an exponential
distribution of time between failures would predict. Regardless, having to
handle anywhere close to hundreds of failures in one minute is exceedingly
unlikely.

Other hardware components failure
"""""""""""""""""""""""""""""""""

Other hardware components that are likely to fail include network cards,
CPUs, DRAM, motherboards and other components internal to a node, as well
as network switches, power distribution units, cables and other components
that make up the cluster infrastructure. Any internal component can cause a
node failure, while infrastructure failure can bring down many nodes at once.

Anecdotal evidence [3]_, data reported by Schroeder and Gibson as well as
data found in another publication by Schroeder and Gibson [4]_ suggest that
hard disk failures are the most common failures in a cluster, but not the
majority cause. Ultimately, whichever hardware component failure is the root
cause, anecdotal evidence by Google [5]_ suggests that the number of individual
node failures can be expected to be half as high as the number of nodes in the
cluster. This estimate by Google is roughly consistent with the large-scale of
many different HPC systems conducted by Schroeder and Gibson, who observe that
the failure rate per processor per year is consistently close to 0.25 across a
variety of systems. These failures are largely due to hardware faults, rather
than software. Failure rates in the cluster correlate better with number of
processors than with number of nodes presumably because the number of
processors is a good estimator of the number of hardware components in a node.
Failure rates of many-core systems of the future is unknown, but an educated
guess based on the above references might be 0.5 to 10 failures per node per
year on average.

The above analysis implies that the HA subsystem must be able to
handle up to 1M node failures per year in a cluster of 100K nodes,
i.e. 2 failures/minute.

Cluster infrastructure failures
"""""""""""""""""""""""""""""""

Google gives a few numbers [5]_ about cluster wide failures:

	“one power distribution unit will fail, bringing down 500 to 1,000
	machines for about 6 hours; 20 racks will fail, each time causing 40 to
	80 machines to vanish from the network; 5 racks will "go wonky," with half
	their network packets missing in action; and the cluster will have to be
	rewired once, affecting 5 percent of the machines at any given moment over
	a 2-day span.”

Again, assuming independent failures of PDU’s and racks, these numbers are
well within what a centralized HA coordinator should be able to handle.
However, in this case, a key feature of the architecture presented here to be
able to handle this many simultaneous features is the scalable communication
tree, in which intermediate “proxy” nodes filter and aggregate failure reports
in order to avoid overflowing the HA coordinator with individual reports.

Significant driving requirements
++++++++++++++++++++++++++++++++

The fundamental bottleneck to be solved is to design an HA subsystem
that scales to managing exascale clusters. But further to this
requirement, we formulate the following additional quality attributes.

This HA subsystem must be able to monitor liveness, collect statistics
about, start, stop and recover the components of the distributed
application that it manages, and achieve cluster-wide consensus about
the new state of the system in response to failures. The new state of
the system in particular includes the (possibly changed) location of
active components.

Additional quality attributes are given in the table below, and
motivated briefly below.

+------------------+-------------------+------------------+----------------+
| Design Qualities | Runtime Qualities | System Qualities | User Qualities |
+==================+===================+==================+================+
| Extensibility    | Availability      | Supportability   | Usability      |
+------------------+-------------------+------------------+----------------+
| Reusability      | Interoperability  | Testability      |                |
+------------------+-------------------+------------------+----------------+
|                  | Manageability     | Variability      |                |
+------------------+-------------------+------------------+----------------+
|                  | Performance       | Analyzability    |                |
+------------------+-------------------+------------------+----------------+
|                  | Reliability       |                  |                |
+------------------+-------------------+------------------+----------------+
|                  | Scalability       |                  |                |
+------------------+-------------------+------------------+----------------+

- **Reusability and extensibility:** High-availability is often baked
  into services in a monolithic fashion. In contrast, the HA subsystem
  described here, Halon, is intended as a modular and reusable
  component, acceding to the high-availability needs of many different
  services and applications in a variety of contexts. In fact, Halon
  should be extensible to the point of becoming a solution for
  tracking resource types that make up the global state of the
  cluster. It is this extensibility that enables reusability of this
  component for the needs of a variety of applications and other
  services in the cluster.

- **Availability:** the subsystem should take the form of a service,
  continuously available to all applications in the cluster. If Halon
  becomes unavailable, then no recovery can take place or only
  partially. This can in turn reduce the availability of the other
  services in the cluster. Our goal is to satisfy :abbr:`SLA's
  (service level agreement)` that included a 99.999% (5 sigmas)
  availability requirement.

  There are two levels of availability:

  - a guarantee that recovery is always possible,
  - a guarantee that every request receives a response about whether
    it succeeded or failed.

  It is easier and desirable to provide extremely strong request
  response availability even if as good recovery availability may not
  be achievable.

  Related to availability is partition tolerance. If Halon cannot
  tolerate :term:`network partitions <network partition>` in the
  cluster, then it is not available and cannot aid in performing
  recovery for at least one of the subnets thus formed, or in fact for
  any subnet in the worst case (in the case of multiple concurrent
  partitions). But a consequence of the :term:`CAP theorem` is that
  request response availability and strong consistency can only be
  provided at the expense of partition tolerance. Since the context of
  Halon is that of large, typically well-equipped storage and compute
  clusters, where at least 2 redundant networks (data and management)
  if not 3 or 4 are available, we prefer to sacrifice partition
  tolerance for :term:`strong consistency <consistency>`. We make the
  assumption that it is possible to deploy Halon in such a way that
  a core group of nodes hosting the service can be redundantly
  connected using 2 or more fully independent networks and that
  therefore true splits rendering communication impossible are highly
  unlikely.

TODO: other QA's.

Solution background
~~~~~~~~~~~~~~~~~~~

Architectural approaches
++++++++++++++++++++++++

The principal architecture pattern of Halon is that at its core
lies a centralized coordination service for the entire cluster. This
HA coordinator is made to be “immortal”, in the sense that debilitating
failure that would make any kind of progress of the coordinator
impossible is exceedingly unlikely. In other words, the HA coordinator
is highly tolerant to failures and highly available. The existence of
such a resilient service that is unique for all the cluster nodes that
it manages greatly simplifies the architecture. Indeed, a great many
complications in a distributed setting find an easy solution given a
single point of coordination that we can assume to be highly available.

Note, however, that a centralized coordination service is certainly
not the right answer if larger cluster sizes require the coordinator
to handle upwards of thousands of events per minute. But for the
purposes of HA, we expect that even for extremely large clusters,
involving millions of nodes, this will not nearly be the case (see the
analysis in :ref:`arch-goals-and-context`). Indeed, the HA coordinator
need only respond to failure events and coordinate recovery in
response. As we argue below based on available data about hardware and
software failures in HPC sites and data centers, failure rates make
such a design entirely acceptable.

Requirements coverage
+++++++++++++++++++++

TODO

- **Reusability:** This is achieved through

  #. simple interaction in a uniform way with all processes making up
     a distributed application, and
  #. allowing for the concept of failure and the recovery used by the
     application to be arbitrarily programmable.

View overview
~~~~~~~~~~~~~

The System Overview section explains that one of the key quality
attributes of Halon is reusability. We address this quality attribute
with a layered architecture. Lower layers present entities in a way
that allows for a wide variety of behaviours. Higher layers add
substructure to these entities that in parts fixes their behaviour. In
general, we aim to provide mechanism, not policy.

The layered architecture is reflected in two views, one that shows the
relationships between the various :doc:`abstract structures
<layered-abstract-structures/index>` that we introduce and the other
between :doc:`subsystems <subsystems-uses/index>`. The former are the
objects that are manipulated by the operations of the latter. Within
each view, we order each view packet to match that of the layer it
pertains to.

.. _views:

Views
~~~~~

:doc:`layered-abstract-structures/index`
++++++++++++++++++++++++++++++++++++++++

- **Element type**: abstract structure.
- **Relation type**: "definition depends on".
- **Properties**: name, definition.

This view depicts the “thing”-like structures that the various subsystems that
make up Halon manipulate. The abstract structures are arranged in layers.
A lower-level abstract structure can be defined independently of the higher
level abstract structures. Conversely, defining a higher-level abstract
structure is only possible once the lower-level ones are defined.

These abstract structures serve to *stereotype* many of the runtime components
of Halon. This view only mentions core abstract structures that are
common to all deployments of Halon, but one is free to additionally
define deployment specific abstract structures, such as disk drives, epoch
numbers, etc.

Abstract structures correspond to resource types in the resource graph that
makes up the namespace.

:doc:`subsystems-uses/index`
++++++++++++++++++++++++++++

- **Element type**: subsystem.
- **Relation type**: “uses”.
- **Property types**: name, description.

This view depicts the “systems” that act, manipulate and transform the
“thing”-like structures in the previous view. In order to satisfy the
reusability, modifiability and variability quality attributes, the subsystems
of Halon are organized as a hierarchy of layers.

These subsystems serve to *colour* many of the runtime components of Halon.

:doc:`communicating-processes/index`
++++++++++++++++++++++++++++++++++++

- **Element type**: process.
- **Relation types**: “sends messages to”.
- **Property types**: name, functionality, cardinality of instances.

The constituent parts of the each subsystem in the previous view are processes,
i.e. runtime components. This view shows each component of each subsystem and
how they communicate with each other.

:doc:`data-model/index`
+++++++++++++++++++++++

- **Element type**: data entity.
- **Relation types**: “has one”, “has at least one”, “has many”.
- **Property types**: name, description of attributes, entity constraints,
  population estimates.

Shows the relationships between abstract structures and their cardinalities.
Also lists the attributes of each abstract structure along with the properties
of each attribute. Finally, provides a meta-model of data entities in the
cluster as resources, as present in the namespace.

:doc:`scalable-tree-communication-deployment/index`
+++++++++++++++++++++++++++++++++++++++++++++++++++

- **Element type**: node.
- **Relation types**: “sends message to”.
- **Property types**: name, allocation of services, population estimates.

Shows how services are allocated to nodes and how nodes are connected to each
other. A node is named according to the services that it hosts. Depicts the
flow of information in the cluster and discusses how the number of nodes of each
type may change over time.

:doc:`tracking-station-deployment/index`
++++++++++++++++++++++++++++++++++++++++

- **Software element type**: process from communicating processes view.
- **Environment element type**: node.
- **Relation type**: “allocated to”, “execution migrates to”.
- **Property types**: migration triggers, connectivity.

Shows how the components of the tracking station are deployed to nodes.

Example cluster deployment
++++++++++++++++++++++++++

- **Software element type**: process from communicating processes view.
- **Environment element type**: node.
- **Relation type**: “allocated to”, “execution migrates to”.
- **Property types**: migration triggers.

Shows how components and services might typically be allocated on the
nodes of a cluster.

.. _arch-views-mapping:

Mapping between views
---------------------

TODO

.. _arch-directory:

Directory
---------

.. _arch-glossary:

Glossary
~~~~~~~~

.. glossary::
   :sorted:

   dependent entity
   weak entity

      Depends on the existence of another entity to exist.

   identifying relationship

      An identifying relationship from A to B means the existence of
      B depends on the existence of A; that is, the primary key of
      B contains the primary key of A.

   recovery

      an agreed upon procedure to be performed in response to
      a failure event. Recovery aims to fix or work around a hardware
      or software failure.

   network partition

      refers to the failure of a network device that causes a network
      to be split. That is, nodes A, B on one side of a split can't
      communicate anymore with node C on the other side of the split.
      Note that splits can sometimes be unidirectional.

   CAP theorem
   Brewer's theorem

      states that it is impossible for a distributed system to
      simultaneously provide consistency, availability and
      partition tolerance.

.. _arch-acronyms:

Acronym list
~~~~~~~~~~~~

.. glossary::
   :sorted:

   GUID

      globally unique identifier

   HAMS

      high availability management system

   HLD

      high-level design document

   DLD

      detailed-level design document

   SAD

      software architecture documentation

.. rubric:: Footnotes

.. [1] Clements, Paul, et al. *Documenting software architectures: views
       and beyond.* Addison-Wesley Professional, 2010.

.. [2] Schroeder, Bianca, and Garth A. Gibson. "Disk failures in the
       real world: What does an MTTF of 1,000,000 hours mean to you."
       *Proceedings of the 5th USENIX Conference on File and Storage
       Technologies (FAST)*. 2007.

.. [3] Alex Gorbatchev. `Hardware Components Failures — Survey Results`_.
       May 10, 2012.

.. [4] Schroeder, Bianca, and Garth A. Gibson. "A large-scale study of
       failures in high-performance computing systems." *Dependable
       and Secure Computing, IEEE Transactions on* 7.4 (2010):
       337-350.

.. [5] Steven Shankland. `Google spotlights data center inner workings`_.
       May 30, 2008.

.. [6] TODO: missing footnote in original document.

.. _Hardware Components Failures — Survey Results: http://www.pythian.com/blog/hardware-components-failures-survey-results/

.. _Google spotlights data center inner workings: http://news.cnet.com/8301-10784_3-9955184-7.html?part=rss&tag=feed&subj=NewsBlog

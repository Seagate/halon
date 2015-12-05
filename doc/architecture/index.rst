Architecture documentation
==========================

.. Note::

   This document forms a part of the Halon architecture documentation.
   This documentation follows a standard format published by the SEI,
   that of the “Views and beyond” methodology [1]_.

:doc:`contents`

Documentation roadmap
---------------------

Scope and summary
~~~~~~~~~~~~~~~~~

This documentation provides an overview of the architecture of Halon,
a software solution for high-availability of large clusters and
real-time automated repairs. This set of documents is intended as
a reference for architecture, a starting point for high-level design
(HLD) documents and detailed level design (DLD) documents, and to be
inspected by architects and peer designers for the presence of any
defects.

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

:doc:`scalable-tree-deployment/index`
+++++++++++++++++++++++++++++++++++++

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

System overview
---------------

High-availability management system
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Halon is a high-availability management system (HAMS). This system is
meant to manage deployments of processes in a cluster making up
a distributed application in such a way as to make the distributed
application highly available.

A distributed application is highly available when an agreed procedure
is followed in the case of failures, in such a way that these failures
ultimately cause as little disruption as possible to users of that
application. This agreed procedure is called recovery. In general it
may involve restarting failed processes on the same node they were
running on, failing over the processes hosted by a failed node to another
node, and notifying all other nodes to take appropriate corrective
measures in response to a failure.

High-availability is often baked in to some applications in a monolithic
fashion. In contrast, Halon is intended as a modular and reusable
component, acceding to the high-availability needs of many different
applications in a variety of contexts. This is achieved through
(i) simple interaction in a uniform way with all processes making up
a distributed application and (ii) allowing for the concept of failure
and the recovery used by the application to be arbitrarily programmable.

Functionality
~~~~~~~~~~~~~

The system must be able to monitor liveness, collect statistics about,
start, stop and recover the components of the distributed application that
it manages, and achieve clusterwide consensus about the new state of the
system in response to failures. The new state of the system in particular
includes the (possibly changed) location of active components.

Quality attribute Requirements
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The quality attribute scenarios are given in `Quality attribute scenarios`_
(QAS) user stories. The pertinent quality attributes for this architecture
are the following. A description for each can be found in the
`Quality Attribute Descriptions`_ document.

.. _Quality attribute scenarios: https://docs.google.com/a/parsci.com/document/d/1U_PkkE0CpOFk7sKVI0bFRmvCXRZ-ksfizBIdfGfh7WM/edit#heading=h.dfa5zsh0nrb0

.. _Quality Attribute Descriptions: https://docs.google.com/a/parsci.com/document/d/15h4EVTd0dGuaspjZ0_7wPBfrFhvj7KH5FxoVTvlqI3Y/edit?usp=sharing

+------------------+-------------------+------------------+----------------+
| Design Qualities | Runtime Qualities | System Qualities | User Qualities |
+==================+===================+==================+================+
| Reusability      | Availability      | Supportability   | Usability      |
+------------------+-------------------+------------------+----------------+
|                  | Interoperability  | Testability      |                |
+------------------+-------------------+------------------+----------------+
|                  | Manageability     | Variability      |                |
+------------------+-------------------+------------------+----------------+
|                  | Performance       | Analyzability    |                |
+------------------+-------------------+------------------+----------------+
|                  | Reliability       |                  |                |
+------------------+-------------------+------------------+----------------+
|                  | Scalability       |                  |                |
+------------------+-------------------+------------------+----------------+

Mapping between views
---------------------

TODO

.. _architecture-rationale:

Rationale
---------

Centralized coordinator
~~~~~~~~~~~~~~~~~~~~~~~

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

Note, however, that a centralized coordination service is certainly not
the right answer if larger cluster sizes require the coordinator to
handle upwards of thousands of events per minute. But for the purposes of
HA, we expect that even for extremely large clusters, involving millions
of nodes, this will not nearly be the case. Indeed, the HA coordinator
need only respond to failure events and coordinate recovery in response.
As we argue below based on available data about hardware and software
failures in HPC sites and data centers, failure rates make such a design
entirely acceptable.

Disk failures
+++++++++++++

Current disk drives have a mean time to failure (MTTF) rating of
:math:`10^6` to :math:`1.5 \times 10^6` hours, though Schroeder and Gibson
[2]_ report that in high-performance computing sites and internet services
sites, typical disk replacement rates exceed the vendor supplied rating by
13%, with 2 to 5 times the rating being common and that up to one order of
magnitude higher replacement rates have been observed.

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
recovery time of up to 20 seconds on average is acceptable.

One must be cautious to acknowledge that hardware failures are not
completely uncorrelated - indeed the correlation observed by Schroeder and
Gibson between the number of failures in a given time period and that in the
previous time period is very high. Such high correlation means that a very
rapid succession of failures is even more likely than what an exponential
distribution of time between failures would predict. Regardless, having to
handle anywhere close to hundreds of failures in one minute is exceedingly
unlikely.

Other hardware components failure
+++++++++++++++++++++++++++++++++

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

The above analysis implies that the HA coordinator must be able to handle up
to 1M node failures per year in a cluster of 100K nodes, i.e. 2
failures/minute.

Cluster infrastructure failures
+++++++++++++++++++++++++++++++

Google gives a few numbers [6]_ about cluster wide failures:

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
This architectural pattern is the topic of the next section.

Scalable tree communication
~~~~~~~~~~~~~~~~~~~~~~~~~~~

See :ref:`scalable-tree-communication-rationale` section
in :doc:`scalable-tree-communication-deployment/index`.

Directory
---------

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

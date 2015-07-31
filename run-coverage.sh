#!/bin/bash -e
[ -d coverage ] || mkdir coverage
rm -rf result.tix
fn=$(mktemp --suffix '.tmp')

mix=`find . -name \*.mix`

for m in $mix ; do
    tmp=$(dirname $m)
    echo ${tmp/.hpc\//}
done > $fn;

srcs=''
for x in `cat $fn | uniq` ; do
	tmp=$(echo $x | cut -d "/" -f2)
	srcs+=" --srcdir=$tmp"
done

# Test files should be excluded from report,
# as a. it's doesn't give additional information
#    b. different packages have same module names
#    c. hpc do not generate .mix files for test modules
excludes='
	Test
	Main
	RemoteTables
 	HA.ResourceGraph.Tests
	HA.NodeAgent.Tests
	HA.EventQueue.Tests
        HA.Multimap.ProcessTests
	HA.Multimap.Tests
	HA.RecoveryCoordinator.Mero.Tests
	HA.RecoverySupervisor.Tests
	Flags
	Test.Integration
	Test.Run
	Test.Unit
	Tests
        Network.CEP
        Network.CEP.Buffer
        Network.CEP.Types
        HA.Autoboot.Tests
'
exclude=''
for x in $excludes ; do
	exclude+=" --exclude=$x"
done

hpc sum --union --output=result.tix $exclude $(find . -name \*.tix)
hpc report $srcs --hpcdir='' $exclude result.tix | tee coverage/overall_report.txt
hpc report --per-module $srcs $exclude result.tix | tee coverage/per_module_report.txt
hpc markup --destdir=coverage $srcs $exclude result.tix

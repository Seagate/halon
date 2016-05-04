umask 022

# Select mock config for the kernel we are building with
PROJECT=${JP_NEO_RELEASE:-osaint}
export MOCK_CONFIG=mock_${PROJECT}
PACKAGE=${JP_PACKAGE}
SCM_URL=${JP_SCM_URL}
VERSION=${JP_VERSION:-0.1}
NEO_ID=${JP_NEO_ID:-o.1.0}

RPMVER=${VERSION}.${NEO_ID}
if [ -d ${WORKSPACE}/.git ] ; then
    SCM_VER=$(git rev-list --max-count=1 HEAD | cut -c1-6)
fi
if [ -d ${WORKSPACE}/.svn ] ; then
    SCM_VER=$(svn info ${repo_dir} 2>/dev/null | grep "Revision:" | cut -f2 -d" ")
fi

if [ -n "${SCM_VER}" ] ; then
   RPMREL=${BUILD_NUMBER}.${SCM_VER}
else
   RPMREL=${BUILD_NUMBER}
fi

export RPMREL

rm -rf build_failed

make MOCK_CONFIG=${MOCK_CONFIG} rpm
rval=$?
if [ "$rval" != "0" ] ; then
    touch build_failed
fi

if [ -f build_failed ] ; then
    echo "RPM Build(s) failed"
    exit -3
else
    echo "Complete Build"
    exit 0
fi

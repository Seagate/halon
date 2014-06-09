function getnodeuuid
{
  if [ -f /sys/module/m0mero/parameters/node_uuid ];
  then
    NODE_UUID=$(cat /sys/module/m0mero/parameters/node_uuid)
    return 0
  else
    return 1
  fi
}

function gethostname
{
  local CONFIG="${GENDERS:-/etc/mero/genders}"
  [ ! -f "${CONFIG}" ] && echo >&2 "Can't find genders file: ${CONFIG}" && exit 1
  if getnodeuuid;
  then
    local NODE_NAME="$(nodeattr -f ${CONFIG} -c m0_uuid=${NODE_UUID} 2>/dev/null)"
    [ ! -z "${NODE_NAME}" ]
  else
    return 1;
  fi
}

function queryval
{
  local CONFIG="${GENDERS:-/etc/mero/genders}"
  [ ! -f "${CONFIG}" ] && echo >&2 "Can't find genders file: ${CONFIG}" && exit 1
  local HOST=$1
  local ARG=$2
  GENDERS_VAL=$( nodeattr -f ${CONFIG} -v ${HOST} ${ARG} 2>/dev/null )
  [ ! -z "${GENDERS_VAL}" ]
}

function mym0dendpoint
{
  if gethostname;
  then
    queryval "${NODE_NAME}" "m0_lnet_host" && local node="${GENDERS_VAL}"
    queryval "${NODE_NAME}" "m0_lnet_if" && local m0if="${GENDERS_VAL}"
    queryval "${NODE_NAME}" "m0_lnet_pid" && local m0pid="${GENDERS_VAL}"
    queryval "${NODE_NAME}" "m0_lnet_m0d_portal" && local port="${GENDERS_VAL}"
    [ -z $node -o -z $m0if -o -z $port ] && return 1
    ENDPOINT="${node}@${m0if}:${m0pid}:${port}:1"
  else
    return 1
  fi
}

function query
{
  local CONFIG="${GENDERS:-/etc/mero/genders}"
  [ ! -f "${CONFIG}" ] && echo >&2 "Can't find genders file: ${CONFIG}" && exit 1
  local QUERY="${1}"
  local NODEATTR="${NODEATTR:-"nodeattr"}"
  local NA="$(which $NODEATTR 2>/dev/null)"
  [ ! -x "$NA" ] && echo >&2 "Can't find nodeattr command" && exit 1
  case "$2" in
    h) # haskell [String] format
      local NODES="$(${NA} -f ${CONFIG} -s ${QUERY} 2>/dev/null)"
      local RES=""
      for NODE in ${NODES}
      do
        RES="${RES},\"${NODE}\""
      done
      local LEN="$(expr length "${RES}")"
      RES="$(expr substr "${RES}" 2 "${LEN}")"
      echo "[${RES}]"
      ;;
    c) # comma-separated format
      local NODES="$(${NA} -f ${CONFIG} -c ${QUERY} 2>/dev/null)"
      echo "${NODES}"
      ;;
    *) # attribute query
      local RES="$(${NA} -f ${CONFIG} -v ${QUERY} ${2} 2>/dev/null)"
      echo "${RES}"
      ;;
  esac
}


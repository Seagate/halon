#!/bin/bash
HALON_USER=${HALON_USER:-sspl-ll}
HALON_PASSWORD=${HALON_PASS:-sspl-4ever}
rabbitmqctl add_vhost SSPL
rabbitmqctl add_user ${HALON_USER} "${HALON_PASSWORD}"
rabbitmqctl set_permissions -p SSPL ${HALON_USER} '.' '.' '.*'

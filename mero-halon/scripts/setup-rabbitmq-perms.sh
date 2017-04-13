#!/bin/bash
HALON_USER=${HALON_USER:-sspluser}
HALON_PASSWORD=${HALON_PASS:-sspl4ever}
rabbitmqctl add_vhost SSPL
rabbitmqctl add_user ${HALON_USER} "${HALON_PASSWORD}"
rabbitmqctl set_permissions -p SSPL ${HALON_USER} '.' '.' '.*'

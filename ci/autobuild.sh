#!/usr/bin/env bash

set +x

username="seagate-ssg"
project="castor"
branch="master"

# See https://circleci.com/docs/api/#new-build and
# https://circleci.com/docs/parameterized-builds/
post_data=$(cat <<EOF
{
  "build_parameters": {
    "SUBMODULE_UPDATE": "--remote",
    "UPDATE_COMPONENTS": "true"
  }
}
EOF
)

# Remark $CIRCLE_CI_TOKEN is typically populated in CIRCLE_CI's
# project settings (environment variable tab) which stay secret.
# NOTE: TODO
curl \
  --header "Content-Type: application/json" \
  --data "${post_data}" \
  --request POST \
  https://circleci.com/api/v1/project/$username/$project/tree/$branch?circle-token=$CIRCLE_CI_TOKEN

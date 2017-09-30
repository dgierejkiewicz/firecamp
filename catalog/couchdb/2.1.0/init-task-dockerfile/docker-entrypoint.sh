#!/bin/bash
set -ex

# This script does below things:
# 1) Setup CouchDB.
# 2) Tell the firecamp manage server to set CouchDB service initialized.

#export REGION="us-east-1"
#export CLUSTER="cluster"
#export MANAGE_SERVER_URL="firecamp-manageserver.cluster-firecamp.com:27040"
#export SERVICE_NAME="mycouch"
#export SERVICE_MEMBERS="mycouch-0.cluster-firecamp.com,mycouch-1.cluster-firecamp.com,mycouch-2.cluster-firecamp.com"
#export AVAILABILITY_ZONES="us-east-1a,us-east-1b,us-east-1c"
#export SERVICE_TYPE="couchdb"
#export SERVICE_PORT="5984"
#export OP="Catalog-Set-Service-Init"
#export ADMIN="admin"
#export ADMIN_PASSWORD="passwd"

# check the environment parameters
if [ -z "$REGION" -o -z "$CLUSTER" -o -z "$MANAGE_SERVER_URL" -o -z "$SERVICE_NAME" -o -z "$SERVICE_MEMBERS" -o -z "$AVAILABILITY_ZONES" -o -z "$SERVICE_TYPE" -o -z "$SERVICE_PORT" -o -z "$OP" ]
then
  echo "error: please pass all required environment variables" >&2
  exit 1
fi
# TODO should fetch ADMIN_PASSWORD from the manage server.
# On Set-Service-Initialized, the manage server will delete the ADMIN_PASSWORD.
if [ -z "$ADMIN" -o -z "$ADMIN_PASSWORD" ]
then
  echo "error: please pass the admin and password" >&2
  exit 1
fi

# 1) setup CouchDB cluster
# get all members
OIFS=$IFS
IFS=','
read -a members <<< "${SERVICE_MEMBERS}"
read -a azs <<< "${AVAILABILITY_ZONES}"
IFS=$OIFS

for m in "${members[@]}"
do
  # wait till dns of all nodes are ready
  /waitdns.sh $m
done

count=${#members[@]}

if [ "$count" = "1" ]; then
  # for the single node, http://docs.couchdb.org/en/2.1.0/install/setup.html#install-setup
  curl -X PUT http://$ADMIN:$ADMIN_PASSWORD@${members[0]}:$SERVICE_PORT/_users
  curl -X PUT http://$ADMIN:$ADMIN_PASSWORD@${members[0]}:$SERVICE_PORT/_replicator
  curl -X PUT http://$ADMIN:$ADMIN_PASSWORD@${members[0]}:$SERVICE_PORT/_global_changes
else
  # setup cluster
  # http://docs.couchdb.org/en/2.1.0/cluster/setup.html

  # setup each node, run the following command on each node
  for m in "${members[@]}"
  do
    curl -X POST -H "Content-Type: application/json" http://$ADMIN:$ADMIN_PASSWORD@$m:$SERVICE_PORT/_cluster_setup -d "{\"action\": \"enable_cluster\", \"bind_address\":\"$m\", \"username\": \"$ADMIN\", \"password\":\"$ADMIN_PASSWORD\", \"node_count\":\"$count}\"}"
  done

  # choose the first node as the coordination node to add other nodes
  i=0
  for m in "${members[@]}"
  do
    if [ "$i" = "0" ]; then
      i=1
      continue
    fi

    curl -X POST -H "Content-Type: application/json" http://$ADMIN:$ADMIN_PASSWORD@${members[0]}:$SERVICE_PORT/_cluster_setup -d "{\"action\": \"enable_cluster\", \"bind_address\":\"${members[0]}\", \"username\": \"$ADMIN\", \"password\":\"$ADMIN_PASSWORD\", \"port\": $SERVICE_PORT, \"node_count\": \"$count\", \"remote_node\": \"$m\", \"remote_current_user\": \"$ADMIN\", \"remote_current_password\": \"$ADMIN_PASSWORD\" }"

    curl -X POST -H "Content-Type: application/json" http://$ADMIN:$ADMIN_PASSWORD@${members[0]}:$SERVICE_PORT/_cluster_setup -d "{\"action\": \"add_node\", \"host\":\"$m\", \"port\": \"$SERVICE_PORT\", \"username\": \"$ADMIN\", \"password\":\"$ADMIN_PASSWORD\"}"
  done

  # complete the setup
  curl -X POST -H "Content-Type: application/json" http://$ADMIN:$ADMIN_PASSWORD@${members[0]}:$SERVICE_PORT/_cluster_setup -d '{"action": "finish_cluster"}'

  # http://docs.couchdb.org/en/2.1.0/cluster/databases.html
  # set zone in the /nodes database for every node.
  azCount=${#azs[@]}
  i=0
  for m in "${members[@]}"
  do
    idx=$(($i % $azCount))
    i=$(($i + 1))
    # example node doc: {"_id":"couchdb@172.31.17.161","_rev":"1-967a00dff5e02add41819138abb3284d"}
    rev=$(curl $ADMIN:$ADMIN_PASSWORD@$m:5986/_nodes/couchdb@$m | awk -F "," '{ print $2 }' | awk -F ":" '{ print $2 }' | awk -F "\"" '{ print $2 }')
    curl -X PUT $ADMIN:$ADMIN_PASSWORD@$m:5986/_nodes/couchdb@$m -d "{ \"_rev\":\"$rev\", \"zone\":\"${azs[$idx]}\" }"
  done
fi

# 2) Tell the firecamp manage server to set CouchDB service initialized.
echo "set CouchDB service initialized"

data="{\"Region\":\"$REGION\",\"Cluster\":\"$CLUSTER\",\"ServiceName\":\"$SERVICE_NAME\",\"ServiceType\":\"$SERVICE_TYPE\"}"
curl -X PUT -H "Content-Type: application/json" -d $data "$MANAGE_SERVER_URL/$OP"


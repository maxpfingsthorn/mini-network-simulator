#!/usr/bin/env bash

# Copyright 2016 Max Pfingsthorn
#
# Licensed under the EUPL, Version 1.1 or – as soon they will be approved by the European Commission
# - subsequent versions of the EUPL (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#
# https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software distributed under the Licence
# is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied.
# See the Licence for the specific language governing permissions and limitations under the Licence.

function print_usage {
	echo "disconnect two docker networks previosly connected via connect-networks.sh"
	echo
	echo "usage: disconnect-networks.sh NET1 NET2"
	echo
	echo "where NET1 and NET2 are docker network names."
	echo
	echo "After disconnecting two networks, run update-routes-and-hosts.sh to update routes and"
	echo "hostnames in the containers."
}

net1=$1
net2=$2

if [ -z "$net1" -o -z "$net2" ]; then
	echo "ERROR: need two network names!"
	echo
	print_usage
	exit 1
fi

existingNets=$(docker network inspect -f '{{.Name}} ' `docker network ls -f "type=custom" -q`)

#echo "Existing networks: $existingNets"

if [[ ! "$existingNets" =~ (^|[[:space:]])"$net1"($|[[:space:]]) ]]; then
	echo "First network '$net1' does not exist! create it first."
	echo
	print_usage
	exit 1
fi
if [[ ! "$existingNets" =~ (^|[[:space:]])"$net2"($|[[:space:]]) ]]; then
	echo "Second network '$net2' does not exist! create it first."
	echo
	print_usage
	exit 1
fi

function get_iface_name {
	net1="$1"
	net2="$2"

	id1=$(docker network inspect -f '{{.ID}}' $net1)
	id2=$(docker network inspect -f '{{.ID}}' $net2)

	echo vth${id1: -6}${id2: -6}
}

veth=$(get_iface_name $net1 $net2)

info=$(ip link show label ${veth})
if [ -z "$info" ]; then
	echo "networks $net1 and $net2 do not seem to be connected"
	exit 0
fi


echo "going to disconnect docker networks $net1 and $net2"

if ip link delete ${veth}; then
	echo "networks $net1 and $net2 successfully disconnected, now run update-routes-and-hosts.sh"
else
	echo "ERROR disconnecting networks $net1 and $net2."
	echo "Maybe you are not root or do not have NET_ADMIN capabilities?"
fi
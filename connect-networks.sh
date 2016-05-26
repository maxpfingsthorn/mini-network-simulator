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
	echo "connect two docker networks so traffic can be routed between them"
	echo
	echo "usage: connect-networks.sh NET1 NET2"
	echo
	echo "where NET1 and NET2 are docker network names."
	echo
	echo "After connecting two networks or after connecting new containers to previously connected"
	echo "networks, run update-routes-and-hosts.sh to set routes and hostnames in the containers."
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

if [[ "bridge" != "$(docker network inspect -f '{{.Driver}}' $net1)" ]]; then
	echo "First network '$net1' is not a bridge network, this script can't connect it!"
	exit 1
fi
if [[ "bridge" != "$(docker network inspect -f '{{.Driver}}' $net2)" ]]; then
	echo "First network '$net2' is not a bridge network, this script can't connect it!"
	exit 1
fi

function get_iface_name {
	net1="$1"
	net2="$2"

	id1=$(docker network inspect -f '{{.ID}}' $net1)
	id2=$(docker network inspect -f '{{.ID}}' $net2)

	echo vth${id1: -6}${id2: -6}
}

veth12=$(get_iface_name $net1 $net2)
veth21=$(get_iface_name $net2 $net1)

info=$(ip link show label ${veth12})
if [ -n "$info" ]; then
	echo "networks $net1 and $net2 seem to be connected already"
	exit 0
fi


echo "going to connect docker networks $net1 and $net2"

function get_bridge_name {
	local net="$1"

	explicit_bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' $net)

	if [ -n "$explicit_bridge" ]; then
		echo $explicit_bridge
		return 0
	fi
	
	ip addr show | grep $(docker network inspect -f '{{ (index .IPAM.Config 0).Gateway }}' $net) | awk '{print $NF}'
	return 0
}



br1=$(get_bridge_name $net1)
br2=$(get_bridge_name $net2)

if [ -z "$br1" ]; then
	echo "ERROR: Could not find bridge interface for network $net1"
	exit 1
fi
if [ -z "$br2" ]; then
	echo "ERROR: Could not find bridge interface for network $net2"
	exit 1
fi

#echo "bridges are:"
#echo "br1: " $br1
#echo "br2: " $br2


# add virtual ethernet interfaces
if ip link add ${veth12} type veth peer name ${veth21}; then

	# set up and add to bridge
	ip link set ${veth12} up
	ip link set ${veth12} master $br1

	ip link set ${veth21} up
	ip link set ${veth21} master $br2

	echo "networks $net1 and $net2 successfully connected, now run update-routes-and-hosts.sh"
else
	echo "ERROR connecting networks $net1 and $net2!"
	echo "Maybe you are not root or do not have NET_ADMIN capabilities?"
fi
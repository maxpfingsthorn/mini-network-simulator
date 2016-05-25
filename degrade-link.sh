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
	echo "degrade a connection between two docker networks to simulate WAN or other constrained links"
	echo
	echo "usage: degrade-link.sh NET1 NET2 [options]"
	echo
	echo "where NET1 and NET2 are docker network names that have been previously connected via "
	echo "connect-networks.sh."
	echo
	echo "Note: This script uses netem to set network emulation parameters on specific ethernet"
	echo "      interfaces. It operates on a single interface at a time, which means that the order"
	echo "      of networks given above matter. This way, it is possible to set, e.g., different"
	echo "      bandwidth limits for different directions of the link between the networks."
	echo "      Please see 'man netem' for a detailed description of available options."
	echo
	echo "where options are:"
	echo "  -h | --help                    show this help message"
	echo "  -r | --rate <rate>             bandwidth limit (e.g. 20kbit)"
	echo "  -d | --delay <delay>           packet delay spec"
	echo "                                 (e.g. 200ms or including variance: '200ms 20ms')"
	echo "  -l | --loss <loss>             packet loss spec (e.g. 0.1%)"
	echo "  -p | --duplicate <duplicate>   packet duplication spec (e.g. 0.1%)"
	echo "  -c | --corrupt <currupt>       packet corruption spec (e.g. 0.1%)"
	echo "  -o | --reorder <reorder>       packet reordering spec, requires delay"
	echo "                                 (this is counter-intuitive, read the man page!)"
}

net1=$1
net2=$2

shift
shift

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
	echo "networks $net1 and $net2 do not seem to be connected, can't degrade!"
	exit 1
fi

rate=""
delay=""
loss=""
duplicate=""
corrupt=""
reorder=""

while [[ $# > 0 ]] ;do
	key="$1"

	case $key in
	    -r|--rate)
	    rate="$2"
	    shift
	    ;;
	    -d|--delay)
	    delay="$2"
	    shift
	    ;;
	    -l|--loss)
	    loss="$2"
	    shift
	    ;;
	    -p|--duplicate)
	    duplicate="$2"
	    shift
	    ;;
	    -c|--corrupt)
	    corrupt="$2"
	    shift
	    ;;
	    -o|--reorder)
	    reorder="$2"
	    shift
	    ;;
	    -h|--help|help)
	    print_usage
	    exit 0
	    ;;
	    *)
	            # unknown option
	    ;;
	esac
	shift # past argument or value
done

tc qdisc del dev ${veth} root 2> /dev/null

if [[ -n "$rate" || -n "$delay" || -n "$loss" || -n "$duplicate" || -n "$corrupt" || -n "reorder" ]]; then
	line=""

	if [ -n "$rate" ]; then
		line="$line rate $rate"
	fi
	if [ -n "$delay" ]; then
		line="$line delay $delay"
	fi
	if [ -n "$loss" ]; then
		line="$line loss $loss"
	fi
	if [ -n "$duplicate" ]; then
		line="$line duplicate $duplicate"
	fi
	if [ -n "$corrupt" ]; then
		line="$line corrupt $corrupt"
	fi
	if [ -n "$reorder" ]; then
		line="$line reorder $reorder"
	fi

	echo "setting netem line: '$line'"

	if tc qdisc add dev ${veth} root netem $line; then 
		echo "successfully set network emulation on link from $net1 to $net2"
	else
		echo "ERROR: could not set network emulation on link from $net1 to $net2"
		echo "Maybe you are not root or do not have NET_ADMIN capabilities?"
	fi
else
	echo "No network emulation set for link from $net1 to $net2"
fi

echo "If you want to also affect the other direction (from $net2 to $net1), please run this tool with network names reversed!"
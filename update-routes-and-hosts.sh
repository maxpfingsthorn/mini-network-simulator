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

function print_nsenter_description {
	echo "nsenter is required for running this script. It allows running commands in container"
	echo "namespaces (such as setting ip routes), even if the container does not have the proper"
	echo "capabilities set. Unfortunately, Ubuntu 14.04 ships with an out-dated version of the"
	echo "util-linux package, so you need to install the nsenter utility separately. My suggestion"
	echo "is to use the version supplied by one of the Docker developers:"
	echo
	echo "https://github.com/jpetazzo/nsenter#how-do-i-install-nsenter-with-this"
	echo
	echo "In case you are already using Ubuntu 15.10 or 16.04, install the util-linux package."
	echo "This also applies to other distributions that ship with a util-linux version > 2.26 (e.g."
	echo "Arch Linux and Fedora > 22)."
}

function print_usage {
	echo "updates ip routes and hostnames in /etc/hosts for each docker container, which is part"
	echo "of a docker network that was connected with connect-networks.sh."
	echo
	echo "This script should be run whenever the network topology changes. This happens when new"
	echo "containers are added to connected networks or networks are connected/disconnected."
	echo
	echo "usage: update-routes-and-hosts.sh [options]"
	echo 
	echo "where options are:"
	echo "  -h | --help         show this help message"
	echo "  --nsenter <path>    give an alternative path to the nsenter executable, in case it is"
	echo "                      not in the path."
	echo "                      Currently, nsenter is found in: '$nsenter'"

	if [[ $EUID != 0 ]]; then
		echo
		echo "NOTE: You need to be root to run this script, because of nsenter."
	fi
}

nsenter=$(which nsenter)

while [[ $# > 0 ]] ;do
	key="$1"

	case $key in
	    --nsenter)
	    nsenter="$2"
	    shift
	    ;;
	    -h|--help|help)
	    print_usage
	    if [ ! -x "$nsenter" ]; then 
	    	echo
	    	echo "MISSING DEPENDENCY:"
	    	echo "nsenter was not found on your path, or you did not provide an alternative path, or you"
	    	echo "provided a wrong path!"
	    	echo
	    	print_nsenter_description
	    fi
	    exit 0
	    ;;
	    *)
	            # unknown option
	    ;;
	esac
	shift # past argument or value
done

if [ ! -x "$nsenter" ]; then 
	echo "ERROR: nsenter not found or path (given: '$nsenter') not executable!"
	echo 
	print_nsenter_description
	exit 1
fi

if [[ $EUID != 0 ]]; then
	echo "You need to be root to run this script!"
	exit 1
fi


# go through list of running containers, and for those that are connected to networks that were linked to other networks (with connect-networks.sh), update routes to the connected networks and

connected_nets=""

declare -A extra_hosts_by_net # hosts in net's neighbors that need to go into /etc/hosts
declare -A routes_by_net      # routes for net's neighbor networks

function get_iface_name {
	net1="$1"
	net2="$2"

	id1=$(docker network inspect -f '{{.ID}}' $net1)
	id2=$(docker network inspect -f '{{.ID}}' $net2)

	echo vth${id1: -6}${id2: -6}
}
function get_iface_halfname {
	net1="$1"

	id1=$(docker network inspect -f '{{.ID}}' $net1)

	echo vth${id1: -6}
}

function find_connected_nets_and_hosts {

	echo "collecting network information ..."

	declare -A hosts_by_net
	declare -A subnets_by_net
	declare -A neighbors_by_net
	declare -A components_by_net

	for net in $(docker network inspect -f '{{.Name}} ' `docker network ls -f "type=custom" -q`); do
		veth=$(get_iface_halfname $net)
		info=$(ip link show label ${veth}*)

		if [ -n "$info" ]; then

			num_containers=$(docker network inspect -f '{{len .Containers}}' $net)

			echo " - net $net is connected to another net, and has $num_containers connected containers"

			subnets_by_net["$net"]=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' $net)

			# find hosts for this net
			for cid in $(docker network inspect -f '{{range $k,$v := .Containers}}{{$k}} {{end}}' $net); do
				hostname=$(docker inspect -f '{{.Config.Hostname}}' ${cid})
				ip4=$(docker inspect -f "{{.NetworkSettings.Networks.$net.IPAddress}}" ${cid})

				hosts_by_net["$net"]="${hostname};${ip4} ${hosts_by_net["$net"]}"

				echo "   * hostname ${hostname} is connected to $net with ip ${ip4}"
			done

			if [ -z "$connected_nets" ]; then
				# initialize component of first network
				components_by_net["$net"]=0
				#echo "init component 0 with $net"
			else
				# find corresponding component, or make new component
				components_by_net["$net"]=-1

				# find which other nets its connected to, iterate only over already discovered networks to force a tree
				for net2 in $connected_nets; do
					veth=$(get_iface_name $net $net2)
					if [ -n "$(ip link show label ${veth})" ]; then
						# these two nets are connected
						echo "   ~ connected to $net2"

						if [[ -1 == ${components_by_net["$net"]} ]]; then
							# we don't have a component yet, assign theirs
							components_by_net["$net"]=${components_by_net["$net2"]}
							#echo "part of component ${components_by_net["$net2"]}"
						elif [[ ${components_by_net["$net"]} != ${components_by_net["$net2"]} ]]; then
							# we already have a different component, merge theirs to ours
							old_comp=${components_by_net["$net2"]}

							#echo "merging components (mine) ${components_by_net["$net"]} (theirs) ${components_by_net["$net2"]}"

							for netname in ${!components_by_net[@]}; do
								if [[ $old_comp == ${components_by_net["$netname"]} ]]; then
									#echo "set component of net $netname from ${components_by_net["$netname"]} to ${components_by_net["$net"]}"
									components_by_net["$netname"]=${components_by_net["$net"]}
								fi
							done
						fi
					fi
				done

				if [[ -1 == ${components_by_net["$net"]} ]]; then
					# we did not find a different component to add us to, so make a new one
					IFS=$'\n' max=$(echo "${components_by_net[*]}" | sort -nr | head -n1)
					unset IFS

					let nextcomp=$max+1
					components_by_net["$net"]=$nextcomp
					#echo "made new component for net $net : $nextcomp"
				fi
			fi

			connected_nets="$connected_nets $net"
		fi

	done

	# construct network neighborhoods
	IFS=$'\n' unique_comps=$(echo "${components_by_net[*]}" | sort -nu)
	unset IFS
	#echo "unique components: '$unique_comps'"

	for c in $unique_comps; do
		neighborhood=()

		#echo "Component: $c"

		for net in ${!components_by_net[@]}; do
			net=$(echo $net | sed 's/^\s*\(.*[^ \t]\)\(\s\+\)*$/\1/' )

			if [[ $c == ${components_by_net["$net"]} ]]; then
				neighborhood+=("$net")
				#echo "added $net"
			fi
		done

		#echo "collected neighborhood $c: ${neighborhood[@]}"

		for net in ${neighborhood[@]}; do
			net=$(echo $net | sed 's/^\s*\(.*[^ \t]\)\(\s\+\)*$/\1/' )

			neighbors_by_net["$net"]=""

			for n2 in ${neighborhood[@]}; do
				n2=$(echo $n2 | sed 's/^\s*\(.*[^ \t]\)\(\s\+\)*$/\1/' )

				if [[ "$net" != "$n2" ]]; then
					neighbors_by_net["$net"]="$n2 ${neighbors_by_net["$net"]}"
				fi
			done

			#echo "set neighborhood for $net: ${neighbors_by_net["$net"]}"
		done
	done

	for net in $connected_nets; do
		net=$(echo $net | sed 's/^\s*\(.*[^ \t]\)\(\s\+\)*$/\1/' )

		#echo "constructing things for net $net"

		echo " + $net is transitively connected to ${neighbors_by_net["$net"]}"

		IFS=' ' read -r -a neighbors <<< "${neighbors_by_net["$net"]}"
		unset IFS

		extra_hosts=()

		for n in ${neighbors[@]}; do
			n=$(echo $n | sed 's/^\s*\(.*[^ \t]\)\(\s\+\)*$/\1/' )
			#echo "$net: neighbor $n, with subnets: '${subnets_by_net["$n"]}'"

			IFS=' ' read -r -a subnets <<< "${subnets_by_net["$n"]}"
			unset IFS

			routes_by_net["$net"]="${subnets[@]} ${routes_by_net["$net"]}"

			for bang in ${hosts_by_net["$n"]}; do
				IFS=';' read -r hn ipv4 <<< "$bang"
				unset IFS

				extra_hosts+=("$hn:$ipv4")
			done
		done

		extra_hosts_by_net["$net"]="${extra_hosts[@]}"

	done

	echo "done collecting network information"
}

function is_connected_net {
	local net="$1"
	#echo "checking if '$net' is in '$connected_nets'"
	if [[ "$connected_nets" =~ (^|[[:space:]])"$net"($|[[:space:]]) ]]; then
		return 0
	fi
	return 1
}

find_connected_nets_and_hosts

start_tag="##START Added by update-routes-and-hosts.sh"
end_tag="##END Added by update-routes-and-hosts.sh"

function container_is_managed {
	cid="$1"
	pid=$(docker inspect -f '{{.State.Pid}}' $cid)

	hostsLine=$(${nsenter} -t $pid --mount -- cat /etc/hosts | grep "$start_tag")

	if [ -z "$hostsLine" ]; then # not managed
		return 1
	fi
	return 0
}


# for all containers
for cid in $(docker ps -q); do
	networks=()

	name=$(docker inspect -f '{{.Name}}' $cid | sed -e 's/^\///')
	host=$(docker inspect -f '{{.Config.Hostname}}' $cid)
	pid=$(docker inspect -f '{{.State.Pid}}' $cid)

	#for connected nets
	for net in $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' $cid); do
		net=$(echo $net | sed 's/^\s*\(.*[^ \t]\)\(\s\+\)*$/\1/' )

		#echo "checking network '$net' of container '$name'"

		if is_connected_net $net ; then
			#echo "container $name has connected network: $net"

			networks+=("$net")
		fi
	done


	if [[ ${#networks[@]} > 0 ]] || container_is_managed $cid ; then
		echo

		# apply routes
		echo "applying routes to container '$name' (hostname '$host')"

		# clear extra routes TODO!
		# ${nsenter} -t $pid --net -- ip route | grep -v default | grep -v kernel | while read r || [ -n $r ]; do
		# 	${nsenter} -t $pid -- net -- ip route del $r
		# done 


		# add routes
		for n in ${networks[@]}; do
			IFS=' ' read -r -a routes <<< "${routes_by_net["$n"]}"
			unset IFS

			ip=$(docker inspect -f "{{.NetworkSettings.Networks.$n.IPAddress}}" $cid)

			eth=$(${nsenter} -t $pid --net -- ip addr show | grep $ip | awk '{print $NF}')

			for sub in ${routes[@]}; do
				echo " - add routes to ${sub} via dev $eth (with ip $ip)"

				${nsenter} -t $pid --net -- ip route add ${sub} dev $eth 2> /dev/null
			done

		done

		# apply hosts
		echo "applying hosts to container '$name' (hostname '$host')"

		# clean up old hostnames
		${nsenter} -t $pid --mount -- cat /etc/hosts | sed "/$start_tag/,/$end_tag/d" | ${nsenter} -t $pid --mount -- tee /etc/hosts.cleaned > /dev/null
		${nsenter} -t $pid --mount -- mv /etc/hosts.cleaned /etc/hosts

		for n in ${networks[@]}; do
			IFS=' ' read -r -a hosts <<< "${extra_hosts_by_net["$n"]}"

			for h in ${hosts[@]}; do
				IFS=':' read -r hn ip <<< "$h"

				echo -e " - add hostname: $ip\t$hn"
			done
		done

		# if there are no hostnames
		if [[ ${#networks[@]} > 0 ]]; then

			(
				echo $start_tag
				for n in ${networks[@]}; do

					IFS=' ' read -r -a hosts <<< "${extra_hosts_by_net["$n"]}"

					for h in ${hosts[@]}; do
						IFS=':' read -r hn ip <<< "$h"

						echo -e "$ip\t$hn"
					done

				done
				echo $end_tag
			) | ${nsenter} -t $pid --mount -- tee -a /etc/hosts > /dev/null

		fi


	fi
	
done
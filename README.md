# Docker Networking Simulation

These scripts provide a very rudimentary network simulation using [Docker networks](https://docs.docker.com/engine/userguide/networking/).

Multiple Docker bridge networks (the default type) can be connected with degradable links. Intuitively speaking, the networks are akin to virtual switches to plug it ethernet interface of containers in, and links between them are like network cables between the switches. Traffic shaping on these links with [netem](http://www.linuxfoundation.org/collaborate/workgroups/networking/netem) allows to simulate arbitrary WAN properties.

![Diagram showing the connection between two Docker networks with mini-network-simulator](https://docs.google.com/drawings/d/1lHKbltTuKF3CBrbhcvuQ4sjK1DaGaT8HsbpzYyW-8nE/pub?w=781&amp;h=271)

## Tools

The suite consist of four scripts:

- `connect-networks.sh` allows to connect two existing docker networks.
- `disconnect-networks.sh` allows to disconnect two existing docker networks.
- `update-routes-and-hosts.sh` allows to automatically set ip routes and write hostnames of other connected containers to /etc/hosts of each container.
- `degrade-link.sh` allows to set netem parameters (bandwidth limit, packet delay, loss, duplication, corruption) on a link between two networks. This is directed, the order of networks matters here to allow setting different parameters for each direction (e.g. different bandwidth limit).

All scripts will output verbose help when invoked with the `-h` flag.

## Note

All of these will probably have to be run with sudo, unless your user is allowed to add network interfaces with `ip link add`.

`update-routes-and-hosts.sh` requires root because of the `nsenter` utility used to set routes and write to the /etc/hosts files in the containers.

## Dependencies

- Docker > 1.10
- Bash > 4.0
- nsenter >= 2.26 (from util-linux package for Ubuntu >= 15.10 and other modern distributions or [jpetazzo's build](https://github.com/jpetazzo/nsenter#how-do-i-install-nsenter-with-this) )

The scripts have been tested on Ubuntu 12.04 and 14.04 (with nsenter from jpetazzo) as well as 16.04 (with nsenter from util-linux).

## Example

This assumes you added your used to the docker group and can use the docker command line interface without sudo. Otherwise, prepend sudo to the docker calls.

```bash
# create networks
docker network create test1
docker network create test2

# connect networks
sudo ./connect-networks.sh test1 test2

# degrate link (can be run anytime)
sudo ./degrade-link.sh test1 test2 --delay 200ms
sudo ./degrade-link.sh test2 test1 --delay 100ms

# run docker containers
docker run -itd --net=test1 --name test1cont --hostname test1host ubuntu:trusty bash
docker run -itd --net=test2 --hostname test2host ubuntu:trusty bash

# update routes and hosts of containers
sudo ./update-routes-and-hosts.sh

# attach to first container's bash by name (that's why we gave it one, it was optional)
docker attach test1cont

# you are now connected to the bash running in the first container, and can ping the other from here
ping test2host
```

You should see some output that resembles:
```
PING test2host (172.23.0.2) 56(84) bytes of data.
64 bytes from test2host (172.23.0.2): icmp_seq=1 ttl=64 time=600 ms
64 bytes from test2host (172.23.0.2): icmp_seq=2 ttl=64 time=300 ms
64 bytes from test2host (172.23.0.2): icmp_seq=3 ttl=64 time=300 ms
64 bytes from test2host (172.23.0.2): icmp_seq=4 ttl=64 time=300 ms
```
The first ping packet requires an ack, so the delay is doubled. The rest of the pings show the degradation we set: 200ms from test1 to test2, and 100ms extra from test2 to test1 on the return trip.

If you want to detach from the docker container (exit will stop it), type `Ctrl-p` and `Ctrl-q` in sequence.


## License

This work is licensed under the [EUPL](https://joinup.ec.europa.eu/software/page/eupl), version 1.1 or - once approved by the EC - later versions.

## Funding

This work was supported in part by the European Community Horizon 2020 Programme under grant agreement n. 635491 "Dexterous ROV: effective dexterous ROV operations in presence of communication latencies (DexROV)".
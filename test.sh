#!/usr/bin/env hellish

ssh -p 4242 dlesieur@127.0.0.1
# Inside VM:
docker --version
docker-compose --version
podman --version

# Test Docker works:
docker run hello-world

# Test rootless Podman:
podman run alpine echo "Podman works!"

# Check Docker daemon:
systemctl status docker

## the NAT port 5000 is forwarded for docker registry, so we can even run a local registry and push/pull from our host.

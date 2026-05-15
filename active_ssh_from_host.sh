#!/bin/bash

VM_NAME="${VM_NAME:-debian}"

SSH_HOST_PORT=""
if command -v VBoxManage > /dev/null 2>&1; then
	SSH_HOST_PORT=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| grep "^Forwarding" \
		| grep '"ssh,tcp,' \
		| head -1 \
		| cut -d, -f4)
fi

if [ -z "$SSH_HOST_PORT" ]; then
	SSH_HOST_PORT=$(ssh -G b2b 2> /dev/null | awk '$1 == "port" { print $2; exit }')
fi
: "${SSH_HOST_PORT:=4242}"

ssh-keygen -f ~/.ssh/known_hosts -R "[127.0.0.1]:${SSH_HOST_PORT}" \
	&& echo "Old host key removed for 127.0.0.1:${SSH_HOST_PORT}. Try SSH now:"

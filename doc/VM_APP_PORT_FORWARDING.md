# VM App Port Forwarding

## What Broke

The Docker stack inside the VM was healthy: `https://localhost:4322` returned HTTP 200 from inside `b2b`.

Firefox on the host could not connect because `localhost:4322` on the host is not the same network namespace as `localhost:4322` inside the VM. With VirtualBox NAT, every host-visible port needs a NAT forwarding rule.

The VM had forwarding for the older development ports, but it did not have the osionos / ft_transcendence ports:

```text
4322, 3001, 3002, 3003, 4000, 4100, 4200, 8000, 8001, 8025, 8787, 18200
```

## Quick Fix From The Host

Run this from the machine that owns VirtualBox:

```bash
cd /sgoinfre/students/dlesieur/born2root
make fix_app_ports
```

Then test the exact URL Firefox should open:

```bash
curl -kfsS -o /dev/null -w 'website:%{http_code}\n' https://localhost:4322
```

Expected result:

```text
website:200
```

## Manual Host Commands

Use these if you do not want to run the helper target:

```bash
VM_NAME=debian

for spec in \
  website:4322 \
  osionos-app:3001 \
  osionos-mail:3002 \
  osionos-calendar:3003 \
  osionos-bridge:4000 \
  mail-bridge:4100 \
  calendar-bridge:4200 \
  baas-gateway:8000 \
  baas-admin:8001 \
  mailpit:8025 \
  auth-gateway:8787 \
  vault:18200
do
  name=${spec%%:*}
  port=${spec##*:}
  VBoxManage controlvm "$VM_NAME" natpf1 delete "$name" 2>/dev/null || true
  VBoxManage controlvm "$VM_NAME" natpf1 "$name,tcp,,$port,,$port"
done
```

If the VM is powered off, use `modifyvm` instead of `controlvm`:

```bash
VBoxManage modifyvm debian --natpf1 "website,tcp,,4322,,4322"
```

## Verify From The Host

```bash
VBoxManage showvminfo debian --machinereadable | grep '^Forwarding'
curl -kfsS -o /dev/null -w 'website:%{http_code}\n' https://localhost:4322
curl -kfsS https://localhost:4000/api/auth/bridge/health
curl -fsS http://localhost:8025 >/dev/null
```

## Verify From Inside The VM

```bash
ssh b2b
cd /home/dlesieur/Documents/ft_transcendence
docker compose ps
curl -kfsS -o /dev/null -w 'vm-website:%{http_code}\n' https://localhost:4322
```

The important Docker line is `local-https-proxy`; it should publish these VM ports:

```text
3001-3003, 4000, 4100, 4200, 4322, 8000-8001, 8787, 18200
```

## Host URLs

```text
Website:             https://localhost:4322
osionos app:         https://localhost:3001
osionos bridge API:  https://localhost:4000
Auth gateway:        https://localhost:8787/api/auth
BaaS gateway:        https://localhost:8000
Vault:               https://localhost:18200
Local mail inbox:    http://localhost:8025
osionos Mail:        https://localhost:3002
Mail bridge:         https://localhost:4100
osionos Calendar:    https://localhost:3003
Calendar bridge:     https://localhost:4200
```

## Why Rebuilding Is Not Required

VirtualBox NAT rules live in the VM configuration. You can add, delete, or repair them from the host with `VBoxManage` while the VM is running. A rebuild is only needed when the guest OS itself is broken.

The automation now applies these rules during `make all`, and `make fix_app_ports` repairs an already-created VM.

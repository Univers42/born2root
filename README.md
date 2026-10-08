# born2root — The Automated DevSecOps Environment

> One command to build a complete, LUKS-encrypted, and development-ready Debian VM, without ever opening a graphical interface.

Far beyond a standard 42 Born2beRoot project, this repository is a complete infrastructure framework. If you are tired of manually installing Debian, configuring SSH, or fighting with connection timeouts, this tool automates the entire process.

### Why use this project?
- **100% Automated & Headless:** ISO download, LUKS/LVM partitioning, preseeded Debian installation, and security configuration run entirely in the background (~20 min).
- **Hypervisor Agnostic:** Works seamlessly with QEMU/KVM (ideal if you lack root/sudo rights for kernel modules on campus) or VirtualBox.
- **Development Ready:** Includes a fully automated Neovim IDE configuration, local AI tools (opencode, host-served models), and the Docker ecosystem.
- **Built for the 42 Curriculum:** Acts as a secure, pre-configured foundation for your future projects (Inception, ft_transcendence) with advanced handling of SSH tunnels, local certificates, and port forwarding.

> **Note for the 42 Evaluation:**
> This project is an advanced workflow tool designed to save you time on the rest of the curriculum. Do not blindly clone this repository to pass your Born2beRoot evaluation if you do not understand what the scripts are doing under the hood. Use it, learn from it, but make the code your own.

---

## Quick Start

### Prerequisites
Ensure your host machine has the required dependencies (VirtualBox, xorriso, curl, etc.). You can install them automatically:
```bash
make deps
```

### 1. Clone the Repository

```bash
git clone git@github.com:Univers42/born2root.git --recursive
cd born2root
```

### 2. Check System Compatibility

Before building, verify that your host machine supports the required virtualization extensions and kernel drivers:

```bash
make check_system
make check_driver
```

### 3. Configure the VM

The `born2root.toml` file at the repository root controls the entire build. Open it to configure your settings before building.

**Important:** You must adjust the RAM allocation and set your 42 login.

* Set `ram_mb` in the `[vm]` section. The default might be set very high (e.g., 20480 MB). If you are on a 42 cluster machine, **you must lower this** (e.g., to 2048 or 4096) to prevent your host from crashing. The amount of RAM allocated will directly impact the performance of the VM and the host.
* Set your 42 login in the `[users]` section.

```toml
[vm]
ram_mb = 2048

[users.yourlogin]
password = "tempuser123"
sudo     = true
nvim     = true
```

Validate your configuration to catch any typos before the build starts:

```bash
make config
```

### 4. Build the VM

Run the orchestrator to download the Debian ISO, inject the preseed, create the VM, and run the unattended installation (~20 minutes):

```bash
make all
```

### 5. Connect

`make all` automatically boots the VM and unlocks the LUKS encryption at the end of the installation. You can immediately connect:

```bash
ssh b2b
```

**Note on subsequent sessions:**
When you log out of your host machine or close your session, the VM powers off. When you return, you must manually start the VM and unlock the disk before you can SSH into it:

* If using QEMU: `make qemu_start`
* If using VirtualBox: `make start_vm`

Once the VM is running, you can connect again using `ssh b2b`.

---

## Daily Usage

The commands to manage your VM differ depending on the hypervisor backend selected during the build.

### QEMU/KVM Backend

* **Start and unlock the VM:** `make qemu_start`.
* **Stop the VM:** `make qemu_stop`.
* **Check VM status:** `make qemu_status`.

### VirtualBox Backend

* **Start and unlock the VM:** `make start_vm`.
* **Stop the VM:** `make poweroff`.
* **Check VM status:** `make status`.
* **Escape hatch (open the GUI):** `make gui_vm`.

### Connecting

The orchestrator configures your host's `~/.ssh/config` file automatically. Once the VM is booted and the LUKS disk is unlocked, connect using the provided alias:

```bash
ssh b2b
```

If you need to clone repositories or edit 42 school projects inside the VM, use SSH agent forwarding by adding the `-A` flag:

```bash
ssh -A b2b
```

### Monitoring the Headless System

The VM is entirely headless and boots with `console=ttyS0`. You can view its console output directly from the host:

* **Follow the console live:** `make console`. Using `Ctrl+C` will stop watching the file, but it will not stop the VM.
* **Print the console log:** `make serial_log`.

---

## Advanced Customization: born2root.toml and Profiles

The `born2root.toml` file contains the default configuration for a standard Born2beRoot evaluation. However, this framework is designed to scale for heavier projects that require more disk space, specific LVM partitioning, or additional software (like Docker or AI tools) by using Profiles.

### 1. Disk Layout and LVM Auto-Scaling

The installer uses a dynamic LVM allocation system. Instead of hardcoding partition sizes, it uses floors and shares. You define the overall disk size using the `SIZE_B2B` variable, and the orchestrator calculates the rest.

Inside the `[disk]` section of your configuration file:

* `floor_mb`: The minimum guaranteed space for a volume.
* `share`: The percentage of the remaining disk space this volume receives.
* `cap_mb`: The maximum allowed size for this volume.

Note: The `/var` partition (where Docker lives) is usually configured to take the "rest" of the surplus space.

Before building, you can preview exactly how the disk will be partitioned based on a specific size:

```bash
make partitions SIZE_B2B=30
```

### 2. Creating a Project Profile

To avoid modifying the main `born2root.toml` and risking merge conflicts when updating the repository, you can create isolated configuration profiles for specific projects.

First, copy the base configuration:

```bash
cp born2root.toml profiles/myproject.toml
```

Open `profiles/myproject.toml` and modify only what you need. For example, if you are starting Inception and need more space in `/var` for Docker containers, you can adjust the `[disk]` section. You can also define which features (like Node.js, Claude Code, or Neovim) should be pre-installed by modifying the `[features]` table.

### 3. Building with a Profile

To build a VM using your custom profile, pass the `B2B_CONFIG` variable along with any environment overrides (like disk size or RAM) to the build command.

If you are using QEMU:

```bash
make re BACKEND=qemu B2B_CONFIG=profiles/myproject.toml SIZE_B2B=40 VM_RAM_MB=4096
```

If you are using VirtualBox:

```bash
make re BACKEND=virtualbox B2B_CONFIG=profiles/myproject.toml SIZE_B2B=40 VM_RAM_MB=4096
```

This command will destroy the existing VM (if any) and build a fresh, customized environment from scratch based on your profile's exact specifications.

---

## 42 Ecosystem & Integrated Tools

### 1. The Neovim IDE

The VM ships with a complete, fully configured Neovim environment that is installed automatically on the first boot. It is built on top of `kickstart.nvim` and includes a full IDE plugin layer (file tree, fuzzy finder, git integration, syntax highlighting, and LSP support).

* You do not need to run any manual setup scripts.
* Simply connect to the VM and type `nvim`.
* The setup installs the upstream Neovim release (e.g., version 0.12), bypassing the older Debian `apt` packages.

### 2. Inception & Host Access

This VM serves as a foundation for the 42 Inception project. You can clone, build, and verify the Inception stack inside the VM using a single command:

```bash
make inception
```

To access the required domain (e.g., `yourlogin.42.fr`) securely from your host machine over HTTPS, you do not need root privileges or manual `/etc/hosts` edits on the host. The orchestrator configures your host's browsers (Firefox and Chrome) to resolve the local domain and trust the VM's local Certificate Authority (CA):

```bash
make host_access
```

You can then prove the stack works correctly from the host side using:

```bash
make verify_access
```

### 3. AI Coding Agents & Local LLMs

The framework includes AI assistants to help with development inside the VM.

* **opencode & Claude Code:** The `opencode` AI coding agent is installed by default in the `standard` installation profile. Anthropic's `claude` (Claude Code) can also be installed as an optional feature or automatically if you use the `full` profile.
* **Local Models on Host GPU:** To avoid hitting campus-wide IP rate limits for cloud AI models, you can run local models directly on your host machine's GPU using `llama.cpp`.
  * Use `make llm_select` to pick a model from Hugging Face and configure your `born2root.toml` file.
  * Use `make llm_host` to download the binary, serve the model on your host, and automatically configure `opencode` inside the VM to use it.

---

## Troubleshooting & Deep Dives

If you encounter issues, the project includes detailed documentation in the `doc/` directory to help you debug common edge cases without cluttering the main README.

### Specific Guides

* **VS Code SSH Disconnections:** If your VS Code Remote SSH connection drops after ~15 minutes of idle time while a standard terminal SSH remains stable, this is a known VirtualBox NAT issue interacting with VS Code's SOCKS proxy. The full explanation and the `settings.json` fix are detailed in `doc/SSH_VSCODE_FIX.md`.
* **Inaccessible App Ports:** If you are running Docker apps inside the VM (like the osionos or ft_transcendence stacks) but cannot reach them from your host browser, you might be missing NAT port forwarding rules. See `doc/VM_APP_PORT_FORWARDING.md` for the diagnosis and the fix.
* **Host SSL/TLS Certificate Errors:** If your browser shows a `SEC_ERROR_UNKNOWN_ISSUER` or `ERR_CERT_AUTHORITY_INVALID` warning when accessing your local Inception domain, your host does not trust the VM's generated Certificate Authority. Follow `doc/HTTPS_FROM_HOST_STEP_BY_STEP.md` to properly import the CA into your browser's trust store.

### Disk Space Management

The virtual machine can consume significant disk space over time. You can manage your footprint using the built-in Makefile targets:

* **Check Quota:** Run `make space` to see your project's current footprint and verify if it fits within your allocated budget.
* **Reclaim Space:** Run `make slim` to delete the downloaded installation ISOs, clear the `apt` cache, and trim freed blocks from the disk. Using `make slim COMPACT=1` will also rewrite the qcow2 image to drop unreferenced clusters (requires the VM to be stopped).

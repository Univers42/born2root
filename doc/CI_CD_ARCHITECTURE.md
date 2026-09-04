# Continuous Integration (CI/CD) in Infrastructure as Code (IaC)

This document details the architecture, objectives, and tooling of the Continuous Integration (CI) pipeline designed for the Born2beRoot project. Unlike traditional software repositories where source code is compiled into binaries, in Infrastructure as Code (IaC), our goal is to validate that the provisioning scripts, configuration files (preseed), and orchestration (Make) reliably and deterministically deploy a virtual machine without regressions.

---

## 1. Pipeline Objectives

1. **Prevention of Structural Disasters:** A typographical error in a Bash script executed as `root` during the unattended installation could corrupt the filesystem. The CI pipeline must catch these logical errors before the code is merged into the main branch.
2. **Code Standardization:** In a collaborative team environment, it is crucial that Bash scripts and Makefiles maintain strict uniformity to guarantee long-term maintainability.
3. **Isolated Component Validation:** Ensuring the integrity of ISO generation (`xorriso`) and the syntax of the `preseed.cfg` file without the overhead of booting a full virtual machine.
4. **Integration Testing (Future Scope):** Once QEMU hypervisor support is fully stabilized, validate the end-to-end installation using Nested Virtualization in CI runners.

---

## 2. Selected Toolchain (Linter and Testing Suite)

For the static analysis phase, we have selected a stack of highly compatible tools. `ShellCheck` will handle code security and logic, while `bashate` and `shfmt` enforce stylistic consistency.

### 2.1 ShellCheck
The industry standard for static analysis of shell scripts. It detects security vulnerabilities, quoting issues, and deprecated or hazardous commands.

**Example usage in CI:**
```bash
# Scans all scripts within the setup directory
shellcheck setup/**/*.sh preseeds/b2b-setup.sh
```

**Practical example (Prevention):**
```bash
# ❌ DANGEROUS CODE (ShellCheck fails with SC2086):
rm -rf $DIR_PATH/*  # If DIR_PATH is empty, this evaluates to 'rm -rf /*'

# ✅ SECURE CODE (Enforced by CI):
rm -rf "${DIR_PATH:?Error: Empty path variable}"/*
```

### 2.2 Bashate
A Bash style linter originally created by the OpenStack team. It enforces strict stylistic rules (akin to PEP8 for Python), ensuring no deprecated syntax or trailing whitespaces are merged.

**Example usage in CI:**
```bash
# Fails the pipeline if stylistic errors are found
bashate setup/**/*.sh
```

**Practical example (Prevention):**
```bash
# ❌ REJECTED CODE (E010, E011):
function setup_vm {    
    echo "Hello"
} # Trailing whitespace on line 2

# ✅ ACCEPTED CODE:
setup_vm() {
    echo "Hello"
}
```

### 2.3 shfmt
An automatic code formatter (written in Go) that parses and rewrites shell scripts to ensure mathematically perfect indentation and line breaks, respecting the existing `.editorconfig` rules.

**Example usage in CI:**
```bash
# The -d flag displays a diff and fails the CI if formatting is incorrect
shfmt -d setup/**/*.sh

# To automatically fix issues locally before committing:
shfmt -w setup/**/*.sh
```

**Practical example (Auto-formatting):**
```bash
# ❌ BEFORE FORMATTING (Chaotic):
if [ "$1" = "start" ];then
echo "Starting..."; fi

# ✅ AFTER SHFMT:
if [ "$1" = "start" ]; then
    echo "Starting..."
fi
```

### 2.4 GNU Make (Dry-Run)
As the `Makefile` serves as the primary orchestrator of the project, syntax errors that break automation are unacceptable. We utilize GNU Make's native validation.

**Example usage in CI:**
```bash
# Simulates execution without performing actual modifications.
# Fails with exit code 2 if syntax errors or circular dependencies exist.
make --dry-run all
```

**Practical example (Prevention):**
Detects the erroneous mixing of spaces and tabs in the Makefile, or rules that depend on non-existent files.

### 2.5 Markdownlint
Ensures that documentation files (`README.md`, `CONTRIBUTING.md`) are structurally sound, devoid of unnecessary HTML, and readable across all markdown viewers.

**Example usage in CI:**
```bash
markdownlint **/*.md
```

---

## 3. Pipeline Architecture (Phased Implementation)

When this system is deployed to GitHub Actions or GitLab CI, it will follow this automated workflow:

1. **Linting Phase (Fail-Fast):** `ShellCheck`, `bashate`, `shfmt`, and `markdownlint` are executed in parallel. If any tool reports an error, the Pull Request is immediately blocked.
2. **Build Phase (Dry-Run):** `make deps` and `make gen_iso` are executed to verify that the preseed integration functions correctly and the custom ISO can be successfully built.
3. **End-to-End Testing (Deferred):** Pending QEMU stability patches, this phase will utilize KVM nested virtualization to execute `make all BACKEND=qemu`, automatically verifying that SSH responds on port `4242`.

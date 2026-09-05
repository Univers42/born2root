# Contributing to Born2beRoot

Thanks for wanting to make this VM builder better. This project automates a complex infrastructure setup from zero to a fully configured virtual machine, and contributions are expected to keep it reliable and idempotent. 

The golden rule:
> **A pull request must solve more than it breaks.** If you can't prove your change is a net improvement, it isn't ready yet.

---

## The flow, start to finish

1. **Fork** the repository to your own account.
2. **Branch** from `main` with a descriptive name (see [naming](#branch-naming)).
3. Make your change. Keep it focused — one concern per PR.
4. **Test thoroughly**. Since this is an infrastructure project, tests mean actually building and verifying the VM (see [the checklist](#the-pre-pr-checklist)).
5. **Document** what you did — in the code (comments), in the commit body, and in the PR description.
6. Open the **PR against `main`** only once you're sure it introduces no regressions.

You never push to `main` directly — it is protected. Everything lands through review.

---

## Branch naming

Use a `type/short-description` slug, matching the kind of work:

```
feat/fedora-host-support       fix/vbox-nat-timeout
refactor/preseed-layout        docs/add-contributing
chore/update-hellish-version
```

---

## Commit format

Commits follow **Conventional Commits**:

```
type(scope): short imperative description

Optional body explaining the WHAT and especially the WHY. Wrap at ~72 cols.
Reference issues like: Closes #123.
```

- **type**: `feat`, `fix`, `refactor`, `docs`, `chore`, `style`.
- **scope**: the component — `iso`, `host`, `vm`, `scripts`, `preseed` (optional but encouraged).
- Keep the subject ≤ ~72 chars, imperative mood ("add", not "added").

---

## The pre-PR checklist

Run all of these from a clean tree. Every one must pass before you open a PR.

- [ ] **Dependency check passes.** Run `make deps` on your host. If you added a new host requirement, ensure it gracefully handles missing packages across different Linux distributions (e.g., Debian/Ubuntu vs. Fedora/RHEL).
- [ ] **Clean VM build.** Your change must not break the automated installation. You must be able to run `make re` (which destroys the VM and rebuilds it from the ISO) and reach a fully working, SSH-accessible machine without manual intervention.
- [ ] **Idempotency.** Running `make all` on a machine that is already built must boot the existing machine, not destroy it or fail with errors.
- [ ] **Host isolation.** Scripts running on the host (in `setup/host/` or `setup/install/`) must not assume the host is a specific Linux distribution unless explicitly checking for it. Avoid hardcoding `apt` without fallback or detection mechanisms.
- [ ] **No regressions in forwarding.** Ensure the VM's NAT rules and port forwarding remain intact (e.g., SSH on 4242, HTTP on 80).

---

## Code style

Unlike C projects, this repository is heavily based on Bash and GNU Make. The standards remain strict:

- **Comments are block comments only**, placed *before* a function or complex logic block. Explain the *why*, the trick, or the gotcha.
- **Fail fast.** Shell scripts should use `set -e` where applicable. Handle errors gracefully and print meaningful error messages to `stderr`.
- **No hardcoded secrets.** If you need to introduce new credentials, use variables and document them in the README.

---

## Documenting your work

- **In the code:** comment the *why*.
- **In the commit:** a body that explains the reasoning and the bug's root cause.
- **In the PR:** describe the problem, the fix, and how you verified it (which OS you used as a host, how long the build took, etc.).

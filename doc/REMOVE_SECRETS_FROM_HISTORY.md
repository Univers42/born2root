# How to Remove Accidentally Committed Secrets from Git History

When a repository contains sensitive information (like tokens, passwords, or keys) and you attempt to push to GitHub, its Push Protection feature may block your commit. To push your code successfully, you must completely rewrite the repository's history to expunge the secret.

Below is the procedure we followed to remove the `HashiCorp Vault Service Token` from the `note.secret` file across all commits.

## 1. Locate the Leaked File
Identify the file causing the rejection. In our case, the GitHub Push Protection error specified:
> HashiCorp Vault Service Token — locations: commit `5dd639a...` path: `note.secret:3`

## 2. Rewrite History to Remove the File
We used Git's `filter-branch` tool to scrub `note.secret` from the entire history. This method iteratively rewrites all targeted commits, dropping the specific file from the index at every step.

```bash
git filter-branch --force --index-filter 'git rm --cached --ignore-unmatch note.secret' HEAD~10..HEAD
```

*Explanation of parameters:*
* `--force`: Forces `filter-branch` to run even if a previous backup exists or history was already modified.
* `--index-filter`: Much faster than `--tree-filter`. Modifies the index directly (using `git rm --cached`).
* `--ignore-unmatch`: Ensures the script doesn't fail if the file doesn't exist in a particular commit.
* `HEAD~10..HEAD`: We targeted the last 10 commits to cover the point where the secret was introduced up to current.

*(Note: `git filter-repo` is recommended over `filter-branch` in modern Git workflows, but if it is not installed, `filter-branch` perfectly does the job for simple removals).*

## 3. Prevent Future Leaks
To ensure `note.secret` is never accidentally tracked again, we added it to `.gitignore`.

```bash
echo "note.secret" >> .gitignore
git add .gitignore
git commit -m "chore: ignore note.secret"
```

## 4. Push the Rewritten History
Because the commits hashes have been altered, you will need to force-push to update the remote branch.

```bash
git push origin HEAD --force-with-lease
```
*(Always prefer `--force-with-lease` over `--force` to avoid blindly overwriting teammates' work).*

## Troubleshooting
If GitHub Push Protection *still* blocks you because it detects dangling commits, you may need to force Git to expire refs and run garbage collection before pushing:
```bash
git for-each-ref --format="delete %(refname)" refs/original | git update-ref --stdin
git reflog expire --expire=now --all
git gc --prune=now
```

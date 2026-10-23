# tofu-manage-coder.sh

Interactive wrapper around OpenTofu for the Coder environment on AWS. It handles AWS SSO login, remembers your vars file and profile, logs every run, and offers plan, apply, targeted apply and destroy from one menu.

## Prerequisites

- `tofu` (OpenTofu) and the AWS CLI v2 installed
- An AWS SSO profile configured (see [First-time SSO setup](#first-time-sso-setup))
- A vars file, e.g. `vars/example.tfvars`
- The Terraform config must declare an `aws_profile` variable, because the script always passes `--var="aws_profile=<profile>"`

> This script is specific to the AWS/Coder setup. It is not suitable for configs without an `aws_profile` variable (e.g. the Proxmox setup), where tofu would error on the undeclared variable.

## Quick start

```bash
chmod +x tofu-manage-coder.sh
./tofu-manage-coder.sh
```

On startup you are asked for:

1. **Vars file** (tab completes), e.g. `vars/example.tfvars`
2. **AWS profile name**, e.g. `coder-demo`

Both are remembered in `.tofu-manage.env`, so next time just press Enter. The script then checks your SSO session, logs in only if it has expired, runs `tofu init` if needed, and shows the menu.

## Menu options

| # | Option | What it does |
|---|--------|--------------|
| 1 | Plan Only | `tofu plan -out=<name>` with your var-file, profile and tuning settings |
| 2 | Plan & Apply | Plan, show summary, confirm, then apply |
| 3 | Apply Existing Plan | Pick a `.out` file from a list, review it, confirm, apply |
| 4 | Destroy Resources | Type `destroy`, review `plan -destroy`, confirm, then destroy |
| 5 | Plan & Auto-Apply | Plan and apply with no further confirmation |
| 6 | Change vars file / profile | Re-prompt for both and re-check SSO |
| 7 | Re-run AWS SSO login | Logs out and forces a fresh device-code login |
| 8 | Tuning | Set parallelism and refresh on/off |
| 9 | Targeted Plan & Apply | Plan and apply only specific resources or modules |
| 10 | Targeted Destroy | Destroy only specific resources or modules, via a reviewed saved plan |
| 11 | Exit | Plans and logs are kept |

### Tuning (option 8)

- **Parallelism** (default 10): passed as `-parallelism=N` to plan, apply and destroy. Raising it only helps when many independent resources are created, and AWS API rate limits can work against you.
- **Refresh** (default on): turning it off adds `-refresh=false` to plan and destroy, which skips querying every resource and is much faster. Drift made outside tofu will **not** be detected, so keep it on for the first plan of a session and before a destroy.
- Applying a saved plan only receives `-parallelism`. Tofu does not allow planning flags such as `-refresh` when applying a plan file, so refresh has to be chosen at plan time.

### Targeted plan and apply (option 9)

- Enter one or more targets separated by spaces or commas, e.g. `module.coder aws_instance.web`.
- Type `?` to list resources currently in state. New resources not yet applied will not appear, so type those addresses manually.
- The plan is saved as `tofu-targeted-<date>.out` and always needs confirmation.
- Tofu includes the dependencies of a target, so more than the named resource may change.
- Afterwards run option 1 to see what a full plan still wants to change. The target list is cleared after each run.

### Targeted destroy (option 10)

- Enter targets the same way as option 9 (`?` lists resources in state).
- It creates a saved destroy plan (`tofu-destroy-targeted-<date>.out`) and prints the list of resources to be destroyed.
- Tofu destroys the target **and anything that depends on it**, so destroying `module.vpc` can also remove instances, subnets or security groups that live in or reference it. Read the list before confirming.
- You must type `destroy` to proceed, and the destroy applies exactly the plan you reviewed.
- **Option 4 destroys everything** and has no targeting. Use option 10 for partial teardowns.

## Logs and generated files

| Path | Purpose |
|------|---------|
| `logs/<action>-<date_time>.log` | Full output of every plan, apply and destroy, with colours stripped |
| `*.out` | Saved plan files |
| `.tofu-manage.env` | Remembered vars file, profile, last plan, parallelism and refresh |

Follow a long run from a second terminal:

```bash
tail -f logs/<file>.log
```

For long applies, run the script inside `tmux` or `screen` so a dropped connection does not kill it.

Plan files can contain sensitive values. If this directory is a git repo, add these to `.gitignore`:

```
*.out
logs/
.tofu-manage.env
```

## First-time SSO setup

Run this once in the Coder workspace:

```bash
aws configure sso --use-device-code
```

| Prompt | Value |
|--------|-------|
| SSO session name | `session-name` |
| SSO start URL | the access portal URL |
| SSO region | `eu-west-2` |
| Scopes | default (`sso:account:access`) |

Then:

1. Open the URL shown **in your own browser**, enter the code and approve.
2. Back in the terminal, choose the account (Coder Demo) and role.
3. Default region `eu-west-2`, output `json`.
4. Give the profile a clear name such as `coder-demo`.

If you have set up the session before, enter the same SSO session name (`session-name`). It reuses the saved start URL and region, and you may be asked to approve in the browser again.

> A plain `aws configure sso` fails in the workspace because the `127.0.0.1` redirect points at your own machine, not the workspace. Always use `--use-device-code`. The script already does this when it logs in for you.

### Check it works

```bash
aws sts get-caller-identity --profile coder-demo
```

### When the session expires

The script detects this and logs in automatically. To do it by hand:

```bash
aws sso login --profile coder-demo --use-device-code
```

### Using the profile with OpenTofu manually

```bash
export AWS_PROFILE=coder-demo
# or
tofu plan --var="aws_profile=coder-demo"
```

## The `--no-cli-pager` flag

The AWS CLI opens its output in a pager (like `less`) when run interactively, which is why you add `--no-cli-pager` by hand. The script sets `AWS_PAGER=""` at the top, so no pager opens for any `aws` call it makes, and the flag is not needed. If you want the same behaviour in your normal shell, add `export AWS_PAGER=""` to `~/.bashrc` or `~/.zshrc`.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `Unable to locate credentials` | `--profile` (or `AWS_PROFILE`) is missing, or the SSO session has expired |
| SSO setup seems stuck after the browser step | The green browser box is only step one. The terminal still needs account, role and profile name completed |
| `SSO login failed` | Check the URL and code were approved in your own browser, then retry with option 7 |
| `Vars file not found` | Check the path, or use option 6 to re-enter it |
| `Value for undeclared variable aws_profile` | The config does not declare an `aws_profile` variable |
| Not sure what profiles exist | `aws configure list-profiles` or `cat ~/.aws/config` |

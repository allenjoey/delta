# Ansible Playbook that fully automates the "manual" patching of CentOS/RHEL and Debian/Ubuntu, using all known official patches.

Tested on CentOS 7/8 Stream, RHEL 7/8, Debian Ubuntu 18.04 and 20.04.

## Installation

ansible-playbook update-by-group.yml -v

# Simple version
ansible-playbook rhel9-patch-simple.yml

# Dry run to see what would change
ansible-playbook rhel9-patch-simple.yml --check
ansible-playbook update.yml -C -v

# Or check inventory structure
ansible-inventory --graph --vars

# pre-flight checks
# Basic execution
ansible-playbook pre-flight-checks.yml

# With verbose output to see more details
ansible-playbook pre-flight-checks.yml -v

# Extra verbose (shows task execution details)
ansible-playbook pre-flight-checks.yml -vv

# Run against specific host only
ansible-playbook pre-flight-checks.yml --limit pve-203

# Dry run (just show what would be checked, don't actually run)
ansible-playbook pre-flight-checks.yml --check

# Run with different inventory file (if needed)
ansible-playbook pre-flight-checks.yml -i /path/to/different/inventory

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)

## Author Information

Joey Allen
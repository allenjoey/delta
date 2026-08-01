#!/bin/bash

ANSIBLE_PLAYBOOK=`which ansible-playbook`
$ANSIBLE_PLAYBOOK update-by-group.yml --limit alpha_k3s -v

exit 0
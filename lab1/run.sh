#!/bin/bash
ansible-playbook -i inventory.ini -l app -u vagrant playbook.yml

#!/bin/bash
ansible-playbook -i inventory -l app -u vagrant playbook.yml

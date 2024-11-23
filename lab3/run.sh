#!/bin/bash
ansible-playbook -i inventory -l web -u vagrant playbook.yml

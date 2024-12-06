#!/bin/bash
ansible-playbook -i "./inventories/test/hosts" -l openvpn -u vagrant playbook.yml

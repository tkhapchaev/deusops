1. Развернуть виртуальную машину для приложения (app) и виртуальную машину для будущей системы базы данных (db) через Vagrantfile
2. Написать роль установки **PostgreSQL** и плейбук, который ее разворачивает
3. Все параметры должны быть вынесены в переменные, все переменные должны быть префиксованы, значения переменных устанавливаются через group_vars для плейбука, роль должна быть покрыта тестами
4. Добавить возможность смены директории с данными на кастомную
5. Добавить возможность создания баз данных и пользователей
6. ***Добавить функционал настройки streaming-репликации***
7. ***Продумать логику определения master и replica нод СУБД и их настройки при работе роли***
---

Чтобы поднять кластер, запустите скрипт run.sh, который в свою очередь запустит ansible-playbook (перед этмм необходимо поднять vagrant окружение).
```
#!/bin/bash
ansible-playbook -i "./inventories/hosts" -u vagrant playbook.yml
```

Playbook для роли postgresql:
```
---
- name: ensure python is installed
  raw: test -e /usr/bin/python || (apt -y update && apt install -y python3)
  changed_when: false

- name: install necessary system packages
  apt:
    name:
      - "{{ postgresql_common_package }}"
      - gnupg
      - curl
      - ca-certificates
      - python3-pip
      - acl
    state: present
    update_cache: yes

- name: install psycopg2-binary for app servers
  pip:
    name: psycopg2-binary
    state: present
    executable: /usr/bin/pip3

- name: install PostgreSQL client on app servers
  apt:
    name: postgresql-client
    state: present
  when: "'app' in group_names"

- name: install PostgreSQL server and configure common settings
  block:
    - name: run PostgreSQL PGDG script
      shell: "{{ postgresql_repo_path }} -y"
      args:
        creates: /etc/apt/sources.list.d/pgdg.list
      changed_when: false

    - name: create directory for PostgreSQL repository key
      file:
        path: /usr/share/postgresql-common/pgdg
        state: directory
        mode: '0755'
      changed_when: false

    - name: download the PostgreSQL repository signing key
      get_url:
        url: "{{ postgresql_key_url }}"
        dest: "{{ postgresql_key }}"
        mode: '0644'
      changed_when: false

    - name: check if PGDG repository exists
      stat:
        path: "{{ postgresql_sources_list }}"
      register: pgdg_repo

    - name: add PostgreSQL repository to sources list
      shell: |
        echo "deb [signed-by={{ postgresql_key }}] {{ postgresql_repo_url }} $(lsb_release -cs)-pgdg main" > {{ postgresql_sources_list }}
      when: not pgdg_repo.stat.exists
      changed_when: false

    - name: update package list
      apt:
        update_cache: yes

    - name: install PostgreSQL server
      apt:
        name: "{{ postgresql_package }}"
        state: present
        force: yes

    - name: configure pg_hba.conf
      template:
        src: templates/pg_hba.conf
        dest: "{{ pg_hba_conf_path }}"
        owner: postgres
        group: postgres
        mode: '0644'
      notify:
        - restart PostgreSQL service
  when: "'master' in group_names or 'replica' in group_names"

- name: configure master node
  block:
    - name: ensure PostgreSQL service is running on master
      shell: |
        pg_ctlcluster {{ postgresql_version }} main start
      args:
        executable: /bin/bash
      register: postgresql_start_master
      changed_when: "'server starting' in postgresql_start_master.stdout"
      failed_when: "'already running' not in postgresql_start_master.stdout and postgresql_start_master.rc != 0 and 'server starting' not in postgresql_start_master.stdout"

    - name: configure postgresql.conf for master
      blockinfile:
        path: "{{ pg_conf_path }}"
        block: |
          listen_addresses = '{{ postgresql_master_listen_addresses }}'
          wal_level = {{ postgresql_master_wal_level }}
          archive_mode = {{ postgresql_master_archive_mode }}
          archive_command = '{{ postgresql_master_archive_command }}'
          max_wal_senders = {{ postgresql_master_max_wal_senders }}
          hot_standby = {{ postgresql_master_hot_standby }}
      changed_when: false

    - name: create PostgreSQL database
      become_user: postgres
      postgresql_db:
        name: "{{ postgresql_db_name }}"
      register: db_creation
      changed_when: db_creation.changed

    - name: create PostgreSQL user
      become_user: postgres
      postgresql_user:
        name: "{{ postgresql_user_name }}"
      register: user_creation
      changed_when: user_creation.changed

    - name: restart PostgreSQL service on master
      shell: |
        pg_ctlcluster {{ postgresql_version }} main restart
      args:
        executable: /bin/bash
      register: restart_result
      changed_when: "'server starting' in restart_result.stdout or 'restarted' in restart_result.stdout"
      failed_when: "'stopped' in restart_result.stdout or restart_result.rc != 0"
  when: "'master' in group_names"

- name: configure replica node
  block:
    - name: check PostgreSQL service status on replica
      shell: |
        pg_lsclusters | grep "{{ postgresql_version }}" | grep main | awk '{print $3}'
      args:
        executable: /bin/bash
      register: replica_status
      changed_when: false

    - name: stop PostgreSQL service for replica if running
      shell: |
        pg_ctlcluster {{ postgresql_version }} main stop
      args:
        executable: /bin/bash
      register: replica_stop
      changed_when: "'server stopped' in replica_stop.stdout"
      failed_when: "'is not running' not in replica_stop.stdout and replica_stop.rc != 0"
      when: replica_status.stdout.strip() == "online"

    - name: check if PostgreSQL data directory exists
      stat:
        path: "{{ postgresql_data_dir }}"
      register: data_dir_status
      become_user: postgres

    - name: remove existing PostgreSQL data and create new directory
      shell: |
        rm -rf {{ postgresql_data_dir }} &&
        mkdir -p {{ postgresql_data_dir }} &&
        chmod go-rwx {{ postgresql_data_dir }}
      args:
        executable: /bin/bash
      become_user: postgres
      when: data_dir_status.stat.exists
      changed_when: false

    - name: check if standby.signal exists
      stat:
        path: "{{ postgresql_data_dir }}/standby.signal"
      register: standby_signal_check
      become_user: postgres

    - name: perform base backup from master to replica
      command: >
        pg_basebackup -P -R -X stream -c fast -h {{ master_host }} -U {{ replication_user }} -D "{{ postgresql_data_dir }}"
      args:
        creates: "{{ postgresql_data_dir }}/standby.signal"
      become_user: postgres
      when: not standby_signal_check.stat.exists
      changed_when: false

    - name: configure postgresql.conf for replica
      blockinfile:
        path: "{{ pg_conf_path }}"
        block: |
          primary_conninfo = 'host={{ master_host }} port=5432 user={{ replication_user }}'
          hot_standby = on
      changed_when: false

    - name: ensure no existing PostgreSQL processes conflict on replica
      shell: |
        ps aux | grep '[p]ostgres' | awk '{print $2}' | xargs -r kill -9
        ps aux | grep '[p]ostgres' | wc -l
      args:
        executable: /bin/bash
      register: postgres_kill
      ignore_errors: true
      changed_when: postgres_kill.stdout | int > 0

    - name: start PostgreSQL service for replica
      shell: |
        pg_ctlcluster {{ postgresql_version }} main start
      args:
        executable: /bin/bash
      register: replica_start
      changed_when: "'server starting' in replica_start.stdout"
      failed_when: "'already running' not in replica_start.stdout and 'port conflict' not in replica_start.stderr and replica_start.rc != 0"
  when: "'replica' in group_names"
```

Все параметры вынесены в переменные роли, в том числе директория с данными PostgreSQL:
```
---
postgresql_user_name: tkhapchaev
postgresql_db_name: lab5

postgresql_version: "17"
postgresql_package: postgresql
postgresql_common_package: postgresql-common

postgresql_repo_url: "https://apt.postgresql.org/pub/repos/apt"
postgresql_repo_path: "/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh"

postgresql_key_url: "https://www.postgresql.org/media/keys/ACCC4CF8.asc"
postgresql_key: "/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"

postgresql_sources_list: "/etc/apt/sources.list.d/pgdg.list"
postgresql_data_dir: "/var/lib/postgresql/{{ postgresql_version }}/main"

pg_hba_conf_path: "/etc/postgresql/{{ postgresql_version }}/main/pg_hba.conf"
pg_conf_path: "/etc/postgresql/{{ postgresql_version }}/main/postgresql.conf"

postgresql_master_listen_addresses: '*'
postgresql_master_wal_level: replica
postgresql_master_archive_mode: on
postgresql_master_archive_command: '/bin/true'
postgresql_master_max_wal_senders: 5
postgresql_master_hot_standby: on

postgresql_replica_listen_addresses: '*'
postgresql_replica_wal_level: replica
postgresql_replica_archive_mode: on
postgresql_replica_archive_command: '/bin/true'
postgresql_replica_max_wal_senders: 5
postgresql_replica_hot_standby: on
replication_user: postgres
master_host: 192.168.56.204
```

Запуск playbook:\
![image](https://github.com/user-attachments/assets/b83f2b0c-9b22-4f53-becf-e865fe5de48c)

Molecule тесты для роли проходят успешно:\
![image](https://github.com/user-attachments/assets/47d8f6b1-a19e-4836-86c3-1e09c4271f47)

Streaming-репликация, добавление новых пользователей, баз данных и таблиц также работают успешно.\
Добавим данные в созданную ранее таблицу test базы данных lab5:\
![image](https://github.com/user-attachments/assets/a9484cfb-9a88-42e2-8251-56ccecda4783)

Все изменения отображаются на replica ноде:\
![image](https://github.com/user-attachments/assets/b3eee76f-29b5-4724-a780-c1ee857e6d26)

С replica ноды все транзакции read-only:\
![image](https://github.com/user-attachments/assets/c69cc533-2ea7-4b8a-8f2d-d1bef8044355)

---
Хапчаев Тимур Русланович M34071\
Алейников Иван Витальевич M34071

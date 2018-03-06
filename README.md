Zabbix Server and agent
=======================

This roles helps to install zabbix Server and agent across RHEL and Ubuntu variants.
Apart from installing the zabbix server or agent, it install either mariadb or psgrel 
and apply basic hardening, like securing the root account with password, and 
removing test databases. The role can also be used to add databases to the 
MySQL server and create users in the database.

Requirements
------------

This role requires Ansible 1.4 or higher, and platform requirements are listed
in the metadata file.

Role Variables
--------------

Variable used to customized the installaton

Zabbix
```
zabbix_version: 3.4 # Zabbix version

## Database connection ##
#
db_backend: mysql     #Backend - it is posible to use mysql(mariadb) and postgrel
zabbix_db: zabbix     # Zabbix database name
zabbix_user: zabbix   # Zabbix database user user
zabbix_pass: zabbix   # Zabbix databse user password

```
see https://github.com/Sifungurux/ansible-mysql
For mysql variables

NB: at the moment it is need to set password two places

The variables that can be passed to this role and a brief description about
them are as follows:

Add role with
```
    - ansible-zabbix
```
Things missing:
Configuration - webinterface
installation and config - agent
Test - agent install on host and add it to zabbix server



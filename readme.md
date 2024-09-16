* csync2 is not available as YUM RPM packages for RHEL/CentOS/AlmaLinux/Rocky Linux EL8 and EL9 versions.
* [Official csync2 release](https://github.com/LINBIT/csync2) is still on csync2 2.0 dated May 7, 2015 with official csync2 master branch on csync2 2.1.0rc1 dated September 19, 2020.
* Built own csync2 2.0, 2.1.0 and 2.1.1 YUM RPMs for EL8 and EL9 distributions for my [Centmin Mod LEMP stack](https://centminmod.com) usage where:
  * csync2 2.0 RPM is based on official csync2 release.
  * csync2 2.1.0 RPM is based on official csync2 master branch 2.1.0rc1 with code modifications for additional MariaDB MySQL support to accompany 4+ yr old Oracle MySQL and PostgreSQL database support and default sqlite3 support. Also built a separate alternative RPM which is built against a newer [sqlite 3.46.1](https://sqlite.org/changes.html) source code based custom RPM instead of EL8/EL9 default sqlite 3.26 and sqlite 3.34 respective version.
  * csync2 2.1.1 RPM is based on forked csync2 code from https://github.com/erlandl4g/csync2 which in turn is forked from https://github.com/Shotaos/csync2 - keeping modifications for additional MariaDB MySQL support to accompany 4+ yr old Oracle MySQL and PostgreSQL database support and default sqlite3 support. Also built a separate alternative RPM which is built against a newer [sqlite 3.46.1](https://sqlite.org/changes.html) source code based custom RPM instead of EL8/EL9 default sqlite 3.26 and sqlite 3.34 respective version.

csync2 2.1.1 EL8

```
yum -q info csync2

Installed Packages
Name         : csync2
Version      : 2.1.1
Release      : 1.el8
Architecture : x86_64
Size         : 218 k
Source       : csync2-2.1.1-1.el8.src.rpm
Repository   : @System
From repo    : @commandline
Summary      : Cluster synchronization tool
URL          : https://github.com/centminmod/csync2/tree/2.1
License      : GPL-2.0-or-later
Description  : Csync2 is a cluster synchronization tool. It can be used to keep files on
             : multiple hosts in a cluster in sync. Csync2 can handle complex setups with
             : much more than just 2 hosts, handle file deletions and can detect conflicts.
             : It is expedient for HA-clusters, HPC-clusters, COWs and server farms.
```
```
-rw-r--r-- 1 root root 129K Sep 15 17:52 csync2-2.1.1-1.el8.src.rpm
-rw-r--r-- 1 root root  98K Sep 15 17:52 csync2-2.1.1-1.el8.x86_64.rpm
-rw-r--r-- 1 root root 153K Sep 15 17:52 csync2-debuginfo-2.1.1-1.el8.x86_64.rpm
-rw-r--r-- 1 root root  91K Sep 15 17:52 csync2-debugsource-2.1.1-1.el8.x86_64.rpm
-rw-r--r-- 1 root root 4.2K Sep 15 17:52 csync2.spec
```

csync2 2.1.1 EL9

```
yum -q info csync2

Installed Packages
Name         : csync2
Version      : 2.1.1
Release      : 1.el9
Architecture : x86_64
Size         : 208 k
Source       : csync2-2.1.1-1.el9.src.rpm
Repository   : @System
From repo    : @commandline
Summary      : Cluster synchronization tool
URL          : https://github.com/centminmod/csync2/tree/2.1
License      : GPL-2.0-or-later
Description  : Csync2 is a cluster synchronization tool. It can be used to keep files on
             : multiple hosts in a cluster in sync. Csync2 can handle complex setups with
             : much more than just 2 hosts, handle file deletions and can detect conflicts.
             : It is expedient for HA-clusters, HPC-clusters, COWs and server farms.
```
```
-rw-r--r-- 1 root root 129K Sep 15 17:52 csync2-2.1.1-1.el9.src.rpm
-rw-r--r-- 1 root root  95K Sep 15 17:52 csync2-2.1.1-1.el9.x86_64.rpm
-rw-r--r-- 1 root root 158K Sep 15 17:52 csync2-debuginfo-2.1.1-1.el9.x86_64.rpm
-rw-r--r-- 1 root root  86K Sep 15 17:52 csync2-debugsource-2.1.1-1.el9.x86_64.rpm
-rw-r--r-- 1 root root 4.2K Sep 15 17:52 csync2.spec
```
```
yum -y install csync2-2.1.1-1.el9.x86_64.rpm
Last metadata expiration check: 0:16:04 ago on Sun Sep 15 21:14:14 2024.
Dependencies resolved.
=========================================================================================================
 Package                Architecture         Version                    Repository                  Size
=========================================================================================================
Installing:
 csync2                 x86_64               2.1.1-1.el9                @commandline                95 k
Installing dependencies:
 librsync               x86_64               2.3.4-1.el9                epel                        57 k

Transaction Summary
=========================================================================================================
Install  2 Packages

Total size: 152 k
Total download size: 57 k
Installed size: 338 k
Downloading Packages:
librsync-2.3.4-1.el9.x86_64.rpm                                          892 kB/s |  57 kB     00:00    
---------------------------------------------------------------------------------------------------------
Total                                                                    136 kB/s |  57 kB     00:00     
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                 1/1 
  Installing       : librsync-2.3.4-1.el9.x86_64                                                     1/2 
  Installing       : csync2-2.1.1-1.el9.x86_64                                                       2/2 
  Running scriptlet: csync2-2.1.1-1.el9.x86_64                                                       2/2 
  Verifying        : librsync-2.3.4-1.el9.x86_64                                                     1/2 
  Verifying        : csync2-2.1.1-1.el9.x86_64                                                       2/2 

Installed:
  csync2-2.1.1-1.el9.x86_64                          librsync-2.3.4-1.el9.x86_64                         

Complete!
```

csync2 2.1.0 EL8

```
yum -q info csync2

Installed Packages
Name         : csync2
Version      : 2.1
Release      : 1.el8
Architecture : x86_64
Size         : 214 k
Source       : csync2-2.1-1.el8.src.rpm
Repository   : @System
From repo    : @commandline
Summary      : Cluster synchronization tool
URL          : https://github.com/LINBIT/csync2#readme
License      : GPL-2.0-or-later
Description  : Csync2 is a cluster synchronization tool. It can be used to keep files on
             : multiple hosts in a cluster in sync. Csync2 can handle complex setups with
             : much more than just 2 hosts, handle file deletions and can detect conflicts.
             : It is expedient for HA-clusters, HPC-clusters, COWs and server farms.
```
```
-rw-r--r-- 1 root root 119K Sep 14 01:56 csync2-2.1-1.el8.src.rpm
-rw-r--r-- 1 root root  96K Sep 14 01:56 csync2-2.1-1.el8.x86_64.rpm
-rw-r--r-- 1 root root 151K Sep 14 01:56 csync2-debuginfo-2.1-1.el8.x86_64.rpm
-rw-r--r-- 1 root root  89K Sep 14 01:56 csync2-debugsource-2.1-1.el8.x86_64.rpm
-rw-r--r-- 1 root root 5.0K Sep 14 01:56 csync2.spec
```

csync2 2.1.0 EL9

```
yum -q info csync2

Installed Packages
Name         : csync2
Version      : 2.1
Release      : 1.el9
Architecture : x86_64
Size         : 207 k
Source       : csync2-2.1-1.el9.src.rpm
Repository   : @System
From repo    : @commandline
Summary      : Cluster synchronization tool
URL          : https://github.com/LINBIT/csync2#readme
License      : GPL-2.0-or-later
Description  : Csync2 is a cluster synchronization tool. It can be used to keep files on
             : multiple hosts in a cluster in sync. Csync2 can handle complex setups with
             : much more than just 2 hosts, handle file deletions and can detect conflicts.
             : It is expedient for HA-clusters, HPC-clusters, COWs and server farms.
```
```
-rw-r--r-- 1 root root 119K Sep 14 01:56 csync2-2.1-1.el9.src.rpm
-rw-r--r-- 1 root root  93K Sep 14 01:56 csync2-2.1-1.el9.x86_64.rpm
-rw-r--r-- 1 root root 155K Sep 14 01:56 csync2-debuginfo-2.1-1.el9.x86_64.rpm
-rw-r--r-- 1 root root  85K Sep 14 01:56 csync2-debugsource-2.1-1.el9.x86_64.rpm
-rw-r--r-- 1 root root 5.0K Sep 14 01:56 csync2.spec
```
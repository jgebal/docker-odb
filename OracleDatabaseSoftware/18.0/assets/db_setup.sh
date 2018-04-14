#!/bin/bash

# ignore secure linux
setenforce Permissive

# create oracle groups
groupadd --gid 54321 oinstall
groupadd --gid 54322 dba
groupadd --gid 54323 oper

# create oracle user
useradd --create-home --gid oinstall --groups oinstall,dba --uid 54321 oracle

# install required OS components
yum install -y oracle-database-server-12cR2-preinstall.x86_64 \
               perl \
               tar \
               unzip \
               wget

# set download location for Oracle software which are not available for unattended downloads
ORACLE_ASSETS=https://www.salvis.com/oracle-assets

# environment variables (not configurable when creating a container)
echo "export ORACLE_BASE=/u01/app/oracle" > /.oracle_env
echo "export ORACLE_HOME=\$ORACLE_BASE/product/18.0.0/dbhome" >> /.oracle_env
echo "export JAVA_HOME=\$ORACLE_HOME/jdk" >> /.oracle_env
echo "export PATH=/usr/sbin:\$PATH:\$JAVA_HOME/bin" >> /.oracle_env
echo "export PATH=\$ORACLE_HOME/bin:\$ORACLE_HOME/OPatch:\$PATH" >> /.oracle_env
echo "export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib" >> /.oracle_env
echo "export CLASSPATH=\$ORACLE_HOME/jlib:\$ORACLE_HOME/rdbms/jlib" >> /.oracle_env
echo "export TMP=/tmp" >> /.oracle_env
echo "export TMPDIR=\$TMP" >> /.oracle_env
echo "export TERM=linux" >> /.oracle_env # avoid in sqlcl: "tput: No value for $TERM and no -T specified"
chmod +x /.oracle_env

# set environment
. /.oracle_env
cat /.oracle_env >> /home/oracle/.bash_profile
cat /.oracle_env >> /root/.bashrc # .bash_profile not executed by docker

# create directories
mkdir -p /u01/app/oracle
mkdir -p /u01/app/oraInventory
mkdir -p /tmp/oracle
chown -R oracle:oinstall /u01
chown -R oracle:oinstall /tmp/oracle

# install gosu as workaround for su problems (see http://grokbase.com/t/gg/docker-user/162h4pekwa/docker-su-oracle-su-cannot-open-session-permission-denied)
wget -q --no-check-certificate "https://github.com/tianon/gosu/releases/download/1.10/gosu-amd64"  -O /usr/local/bin/gosu
chmod +x /usr/local/bin/gosu

# download and extract Oracle database software
echo "downloading Oracle database software..."
wget -q --no-check-certificate ${ORACLE_ASSETS}/V974953-01.zip -O /tmp/oracle/db1.zip
chown oracle:oinstall /tmp/oracle/db1.zip
echo "creating ORACLE_HOME directory..."
gosu oracle bash -c "mkdir -p $ORACLE_HOME"
echo "extracting Oracle database software..."
gosu oracle bash -c "unzip -o /tmp/oracle/db1.zip -d $ORACLE_HOME" > /dev/null

# install Oracle software into ${ORACLE_BASE}
chown oracle:oinstall /assets/db_install.rsp
echo "running Oracle installer to install database software only..."
gosu oracle bash -c "$ORACLE_HOME/runInstaller -silent -force -waitforcompletion -responsefile /assets/db_install.rsp -ignorePrereqFailure"

# run Oracle root scripts
echo "running Oracle root scripts..."
/u01/app/oraInventory/orainstRoot.sh > /dev/null 2>&1
${ORACLE_HOME}/root.sh > /dev/null 2>&1

# remove original sample schemas to save disk space
rm -r -f ${ORACLE_HOME}/demo/schema

# download and extract Oracle sample schemas
echo "downloading Oracle sample schemas..."
wget -q --no-check-certificate https://github.com/oracle/db-sample-schemas/archive/master.zip -O /tmp/db-sample-schemas-master.zip
echo "extracting Oracle sample schemas..."
unzip /tmp/db-sample-schemas-master.zip -d ${ORACLE_HOME}/demo/ > /dev/null
mv ${ORACLE_HOME}/demo/db-sample-schemas-master ${ORACLE_HOME}/demo/schema
# ensure ORACLE_HOME does not contain soft links to avoid "ORA-22288: file or LOB operation FILEOPEN failed"  (for Oracle sample schemas)
ORACLE_HOME=`readlink -f ${ORACLE_HOME}`
cd ${ORACLE_HOME}/demo/schema
# replace placeholders in files, do not keep original version
perl -p -i -e 's#__SUB__CWD__#'$(pwd)'#g' *.sql */*.sql */*.dat > /dev/null
# reset environment (ORACLE_HOME)
. /.oracle_env
chown oracle:oinstall ${ORACLE_HOME}/demo/schema
rm -f /tmp/db-sample-schemas-master.zip

# remove original APEX folder to save disk space
rm -r -f ${ORACLE_HOME}/apex

# download and extract APEX software
echo "downloading APEX..."
wget -q --no-check-certificate ${ORACLE_ASSETS}/apex_5.1.4_en.zip -O /tmp/apex.zip
echo "extracting APEX..."
unzip -o /tmp/apex.zip -d ${ORACLE_HOME} > /dev/null
chown -R oracle:oinstall ${ORACLE_HOME}/apex
rm -f /tmp/apex.zip

# remove original ORDS folder to save disk space
rm -r -f ${ORACLE_HOME}/ords

# download and extract ORDS
echo "downloading ORDS..."
wget -q --no-check-certificate ${ORACLE_ASSETS}/ords.18.1.1.95.1251.zip -O /tmp/ords.zip
echo "extracting ORDS..."
mkdir /opt/ords
unzip /tmp/ords.zip -d ${ORACLE_HOME}/ords/ > /dev/null
chown -R oracle:oinstall ${ORACLE_HOME}/ords
rm -f /tmp/ords.zip

# cleanup
rm -r -f /tmp/*
rm -r -f /var/tmp/*

#!/bin/bash

reuse_database(){
	echo "Reuse existing database."
	if grep -q "$ORACLE_SID:" /etc/oratab ; then
		# starting an existing container
		echo "Database already registred in /etc/oratab"
	else
		# new container with an existing volume
		echo "Registering Database in /etc/oratab"
		echo "$ORACLE_SID:$ORACLE_HOME:N" >> /etc/oratab
		set_timezone
	fi
	chown oracle:dba /etc/oratab
	chmod 664 /etc/oratab
	provide_data_as_single_volume
	gosu oracle bash -c "${ORACLE_HOME}/bin/lsnrctl start"
	gosu oracle bash -c 'echo startup\; | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
}

link_dir_to_volume(){
	LINK=${1}
	TARGET=${2}
	if  [ -d ${LINK} -a ! -d ${TARGET} ]; then
		echo "Moving original content of ${LINK} to ${TARGET}."
		mkdir -p ${TARGET}
		mv ${LINK}/* ${TARGET} || true
	fi
	rm -rf ${LINK}
	mkdir -p ${TARGET}
	chown -R oracle:dba ${TARGET} 
	echo "Link ${LINK} to ${TARGET}."
	ln -s ${TARGET} ${LINK}
	chown -R oracle:dba ${LINK}
}

provide_data_as_single_volume(){
	echo "Providing persistent data under /u02 to be used as Docker volume."
	link_dir_to_volume "/u01/app/oracle/product/21.0.0/dbhome/dbs" "/u02/app/oracle/product/21.0.0/dbhome/dbs" 
	link_dir_to_volume "/u01/app/oracle/admin" "/u02/app/oracle/admin" 
	link_dir_to_volume "/u01/app/oracle/audit" "/u02/app/oracle/audit"
	link_dir_to_volume "/u01/app/oracle/cfgtoollogs" "/u02/app/oracle/cfgtoollogs"
	link_dir_to_volume "/u01/app/oracle/checkpoints" "/u02/app/oracle/checkpoints"
	link_dir_to_volume "/u01/app/oracle/dbs" "/u02/app/oracle/dbs"
	link_dir_to_volume "/u01/app/oracle/diag" "/u02/app/oracle/diag"
	link_dir_to_volume "/u01/app/oracle/homes" "/u02/app/oracle/homes"
	link_dir_to_volume "/u01/app/oracle/oradata" "/u02/app/oracle/oradata"
	link_dir_to_volume "/u01/app/oracle/ords" "/u02/app/oracle/ords"
	chown -R oracle:dba /u02
}

set_timezone(){
	echo "Change timezone to Central European Time (CET)."
	unlink /etc/localtime
	ln -s /usr/share/zoneinfo/Europe/Zurich /etc/localtime
}

remove_domain_from_resolve_conf(){
	# Workaround to improve startup time of DBCA
	# remove domain entry, see MOS Doc ID 362092.1
	cp /etc/resolv.conf /etc/resolv.conf.ori
	sed 's/domain.*//' /etc/resolv.conf.ori > /etc/resolv.conf
}

create_database(){
	echo "Creating database."
	provide_data_as_single_volume
	remove_domain_from_resolve_conf
	gosu oracle bash -c "${ORACLE_HOME}/bin/lsnrctl start"
	gosu oracle bash -c "/assets/create_database.sh"
	echo "Configure listener."
	gosu oracle bash -c 'echo -e "ALTER SYSTEM SET LOCAL_LISTENER='"'"'(ADDRESS = (PROTOCOL = TCP)(HOST = $(hostname))(PORT = 1521))'"'"' SCOPE=BOTH;\n ALTER SYSTEM REGISTER;\n EXIT" | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
	echo "Save open state of PDB."
	gosu oracle bash -c 'echo -e "ALTER PLUGGABLE DATABASE ${PDB_NAME} OPEN;\n ALTER PLUGGABLE DATABASE ${PDB_NAME} SAVE STATE;\n EXIT" | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
	echo "Applying data patches."
	gosu oracle bash -c "cd ${ORACLE_HOME}/OPatch && (./datapatch -verbose) ; echo $?"
	echo "Workaround for bug 25710407"
	gosu oracle bash -c 'echo -e "EXEC dbms_stats.init_package();\n EXIT" | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
	echo "Setting CONNECT_STRING for default connection."
	export CONNECT_STRING=${PDB_NAME}
	echo "export CONNECT_STRING=${CONNECT_STRING}" >> /.oracle_env
	echo "export CONNECT_STRING=${CONNECT_STRING}" >> /home/oracle/.bash_profile
	echo "export CONNECT_STRING=${CONNECT_STRING}" >> /root/.bashrc
	if [ $APEX == "true" ]; then
		. /assets/install_apex.sh
	fi
	if [ $DBEXPRESS == "true" ]; then
		echo "Enabable XDB HTTP port for EM Database Express."
		gosu oracle bash -c 'echo EXEC DBMS_XDB_CONFIG.setglobalportenabled\(true\)\; | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
		gosu oracle bash -c 'echo EXEC DBMS_XDB.sethttpport\(8080\)\; | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
	fi
	if [ $ORDS == "true" ]; then
		echo "Installing ORDS."
		gosu oracle bash -c "/assets/install_ords.sh"
	fi
	if [ $SCOTT == "true" ]; then
		echo "Installing schema SCOTT."
		# setting TWO_TASK causes connections using O/S authentication to fail, e.g. "sqlplus / as sysdba".
		export TWO_TASK=${CONNECT_STRING}
		${ORACLE_HOME}/bin/sqlplus sys/${PASS}@${TWO_TASK} as sysdba @${ORACLE_HOME}/rdbms/admin/utlsampl.sql
		unset TWO_TASK
	fi
	if [ $SAMPLE_SCHEMAS == "true" ]; then
		echo "Installing Oracle sample schemas."
		. /assets/install_oracle_sample_schemas.sh
	fi
	if [ $FTLDB == "true" -a \( $JSERVER == "true" -o $DBCA == "true" \) ]; then
		echo "Installing FTLDB."
		. /assets/install_ftldb.sh
	fi
	if [ $TEPLSQL == "true" ]; then
		echo "Installing tePLSQL."
		. /assets/install_teplsql.sh
	fi
	if [ $ODDGEN == "true" ]; then
		echo "Installing oddgen examples/tutorials"
		. /assets/install_oddgen.sh
	fi
}

start_database(){
	# Startup database if oradata directory is found otherwise create a database
	if [ -d /u02/app/oracle/oradata ]; then
		reuse_database
	else
		set_timezone
		create_database
	fi

	# start ORDS
	gosu oracle bash -c "/assets/start_ords.sh"

	# Successful installation/startup
	echo ""
	echo "Database ready to use. Enjoy! ;-)"

	# trap interrupt/terminate signal for graceful termination
	trap "gosu oracle bash -c 'echo Starting graceful shutdown... && echo shutdown immediate\; | ${ORACLE_HOME}/bin/sqlplus -S / as sysdba && /assets/stop_ords.sh && ${ORACLE_HOME}/bin/lsnrctl stop'" INT TERM

	# waiting for termination of tns listener
	PID=`ps -e | grep tnslsnr | awk '{print $1}'`
	while test -d /proc/$PID; do sleep 1; done
	echo "Graceful shutdown completed."
}

# set environment
. /assets/setenv.sh

# Exit script on non-zero command exit status
set -e

case "$1" in
	'')
		# default behaviour when no parameters are passed to the container
		start_database
		;;
	*)
		# use parameters passed to the container
		echo ""
		echo "Overridden default behaviour. Run /assets/entrypoint.sh when ready."
		$@
		;;
esac

#!/bin/bash
#################################################################################
#	Script de backup automático do SPED.                                    #
#	Versão: 3.0                                                             #
#									        #
#	Escrito por Hugo Conrado de Carvalho - 3º Sgt, em 26/08/2015.           #
#	Modificado por Lucas da Silva Lemes - 2° Sgt, em 06/06/2018		#
#	 - modificado para versão 2.9 do sped					#
#	 - não necessita mais do arquivo sped.sh				#
#	 - verificar arquivo de configuração do sql (linha 69 do postgresql.conf#
#	   deve estar descomentada)                                             #
#	 - Agora realiza backup do sped.war                                     #
#        - Verifique no HBA.conf se há permissões para pg_dump pelo cron        #
#       Dúvidas: lucasdasilvalemes89@gmail.com					#
#################################################################################

# Declaração de variáveis globais:

DIR_LOCAL=/var/backup_sped_atual
HOST_REMOTO=root@10.56.208.16
DIR_REMOTO=/home/sistemas/sped
DATA=$(date +%Y-%m-%d)
DIR_SPEDWAR=backup_sped.war_$DATA.tar.gz
ARQUIVO_SQL=backup_SPED_$DATA.sql
ARQUIVO_SLAPD=backup_ldap_$DATA.ldif
ARQUIVO_LOG=log_backup_sped_$DATA.txt

# Declaração de funções:

# Realiza a compactação da pasta do webapps.
backup_sped_war () {
	echo "Criando a cópia do sped.war..." >> $LOG
	SPEDWAR="$DIR_LOCAL/$DIR_SPEDWAR"
	tar zcvfp $SPEDWAR /var/lib/tomcat7/webapps/sped.war >> $LOG;
	if  [ $? -eq 0 ]
	then	echo "Cópia criada com sucesso." >> $LOG
		return 0
	else	echo "Falha ao criar cópia do sped.war" >> $LOG
		return 2
	fi
}

# Cria um dump da base ldap.
backup_slapd () {
	echo "Fazendo o backup da base do LDAP..." >> $LOG
	SLAPD="$DIR_LOCAL/$ARQUIVO_SLAPD"
	slapcat -l $SLAPD >> $LOG 2>> $LOG;
	if [ $? -eq 0 ]
	then	echo "Backup do slapd criado com sucesso." >> $LOG
		return 0
	else	echo "Erro: o arquivo do slapd não foi criado." >> $LOG
		return 4
	fi
}

# Cria o dump da base de dados PostgreSQL.
backup_postgres () {
	PATH="$PATH"/usr/bin
	echo "Criando o dump da base PostgreSQL..." >> $LOG
	SQL="$DIR_LOCAL/$ARQUIVO_SQL"
	# O comando do postgres tem de ser executado numa linha só, com a opção '-c'.
	sped start >> $LOG
	service tomcat7 stop >> $LOG
	#su - postgres -c "/usr/bin/pg_dump -E UTF8 -v spedDB > $SQL" >> $LOG
	pg_dump -U postgres -E UTF8 -v spedDB > $SQL
	if [ $? -eq 0 ]
	then	echo "Dump da base criado com sucesso" >> $LOG
		return 0
	else	echo "Erro: não foi possível criar o dump do PostgreSQL." >> $LOG
		return 1
	fi
}

# Copia os arquivos que foram gerados com sucesso para o servidor remoto.
copiar_backup () {
	ST_CP=0

	# Ajusta os nomes de diretório para contemplarem o dia do backup.
	DIR_REMOTO="$DIR_REMOTO"/"$DATA"
	echo "Criando a pasta de backup no servidor remoto..." >> $LOG
	ssh "$HOST_REMOTO" mkdir "$DIR_REMOTO" 2>> $LOG;
	DIR_REMOTO="$DIR_REMOTO"/sped
	ssh "$HOST_REMOTO" mkdir "$DIR_REMOTO" 2>> $LOG;

	# Testa se o diretório remoto existe.
	if ssh "$HOST_REMOTO" test -d "$DIR_REMOTO";
	then	echo "Diretórios prontos. Iniciando as cópias..." >> $LOG
	else	echo "Erro: Não foi possível acessar o diretório remoto." >> $LOG
		return 128
	fi

	# Testa a existência do arquivo do webapps:
	if [ -e "$WEBAPPS" ]
	then	echo "Copiando o webapps para o servidor remoto..." >> $LOG
		if scp "$WEBAPPS" "$HOST_REMOTO":"$DIR_REMOTO";
		then	echo "Arquivo copiado para o servidor remoto." >> $LOG
		else	echo "Erro ao copiar o arquivo." >> $LOG
			(( ST_CP += 16 ))
		fi
	else	echo "Atenção: o arquivo do Webapps não foi encontrado." >> $LOG
		(( ST_CP += 16 ))
	fi

	# Testa a existência do arquivo do slapd:
	if [ -e "$DIR_LOCAL/$ARQUIVO_SLAPD" ]
	then	echo "Copiando o arquivo de backup do slapd..." >> $LOG
		if scp "$DIR_LOCAL/$ARQUIVO_SLAPD" "$HOST_REMOTO":"$DIR_REMOTO";
		then	echo "Cópia concluída com sucesso." >> $LOG
		else	echo "Erro ao copiar o arquivo." >> $LOG
			(( ST_CP += 32 ))
		fi
	else	echo "Atenção: o arquivo do slapd não foi encontrado." >> $LOG
		(( ST_CP += 32 ))
	fi

	# Testa a existência do arquivo do SQL:
	if [ -e "$DIR_LOCAL/$ARQUIVO_SQL" ]
	then	echo "Copiando o arquivo de backup do SQL..." >> $LOG
		if scp "$DIR_LOCAL"/"$ARQUIVO_SQL" "$HOST_REMOTO":"$DIR_REMOTO";
		then	echo "Cópia concluída com sucesso." >> $LOG
		else	echo "Erro ao copiar o arquivo." >> $LOG
			((ST_CP += 8 ))
		fi
	else	echo "Atenção: o arquivo do sql não foi encontrado." >> $LOG
		(( ST_CP += 8 ))
	fi

	# Retorna a soma dos estados de erro de cada cópia.
	return "$ST_CP"
}

# Remove os arquivos de backup antigos:
remover_antigos () {
	cd "$DIR_LOCAL"
	echo "Removendo arquivos de backups anteriores do servidor local..." >> $LOG
	rm `ls | grep -vE "$ARQUIVO_LOG|$ARQUIVO_SQL|$ARQUIVO_SLAPD|$DIR_TOMCAT7"`
	if [ $? -ne 0 ]
	then	return 256
	fi
	return 0
}


# Início do script
# Ajusta o PATH, para bypassar o default do cron:
PATH="$PATH":/usr/sbin:/usr/bin:/bin:/usr/local/bin:/usr/local/bin/sped

# Inicializa o arquivo de log, se já existia antes:
LOG="$DIR_LOCAL/$ARQUIVO_LOG"
echo "Log do backup realizado em $(date "+%d/%m/%Y %H:%M")." > $LOG

# Inicia com tudo ok.

STATUS=0
STATUSSV=0
sleep 15
sped stop >> $LOG
(( STATUSSV = $? ))
echo $STATUSSV >> $LOG
if [ $STATUSSV -eq 0 ];
then	echo "Serviços parados. Iniciando o backup." >> $LOG
else	echo "Erro ao interromper os serviços do sped. Interrompendo backup." >> $LOG
	sped restart >> $LOG;
	exit 64
fi

# Realiza as operações sequencialmente, somando o estado de saída das mesmas.

rm -rf /var/backup_sped_atual/* && sleep 300

backup_sped_war;
(( STATUS = $? ))

backup_slapd;
(( STATUS += $? ))

backup_postgres;
(( STATUS += $? ))

# Reinicia o sped, independente do resultado do backup.
sped start >> $LOG;

echo "Iniciando a cópia dos arquivos para o servidor remoto..." >> $LOG
copiar_backup;
(( STATUS += $? ))

# Se deu tudo certo até agora, tenta remover os arquivos de backups antigos.
if [ $STATUS -eq 0 ]
then	echo "Cópia dos arquivos concluída com sucesso." >> $LOG
	remover_antigos;
	(( STATUS += $? ))
else	echo "Houve erros durante o backup. Os arquivos anteriores não serão removidos." >> $LOG
fi

if [ $STATUS -eq 0 ]
then	echo "Não houve erros durante o backup." >> $LOG
else	echo "Houve erros durante o backup: código $STATUS." >> $LOG
fi

# Verifica se hove erro ao criar as pastas no servidor remoto:
if (( ( ( STATUS / 128 ) % 2 ) != 1 ))
then	echo "Realizando a cópia do log para o servidor remoto..." >> $LOG
	scp "$LOG" "$HOST_REMOTO":"$DIR_REMOTO"
else	echo "Atenção: o log não foi copiado para o servidor remoto." >> $LOG
fi

echo "Fim do processo de Backup!" >> $LOG

# Retorna o valor somado das saídas.
exit "$STATUS"

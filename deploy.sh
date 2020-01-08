#!/usr/bin/env bash
# Script Name: deploy.sh
#
# Author: John Russell (john.russell@ironeaglex.com)
# Date : 08/20/2019
#
# Description: The following script deploys compiled ck resources
#
# Run Information: This script should be run any time frontend or backend resources are built in the Jenkins pipeline.

usage()
{
    echo "Usage: deploy.sh <-f | -j | -a>"
    echo "-f: deploy compiled Angular front end"
    echo "-j: deploy compiled Java (WAR) file"
    echo "-a: deploy both"
}

spinner()
{
	i=$1
	sp="/-\|"
	printf "\b${sp:i++%${#sp}:1}"
}

seed()
{
	# USER=$1
	# PASS=$2
	#Get CK templates from bitbucket
	#TODO: Get CK templates form S3
	if [ ! -z "$AWS_PATH" ]; then
		echo "We're on AWS... using S3 bucket instead of S3ninja"
	elif [[ ! -d "s3ninja/castlekeep-templates" || ! $(ls -A "s3ninja/castlekeep-templates") ]]; then
		echo "Copying CK templates from bitbucket"
		git clone https://bitbucket.di2e.net/scm/ckf/ck-systems.git tmp/ck-systems;
		mv tmp/ck-systems/castlekeep-templates s3ninja/;
		rm -rf tmp/ck-systems;
	else
		echo "CK templates are already loaded... skipping templates!"
	fi
	
	if [ "$(curl -s -o /dev/null -w ''%{http_code}'' -I -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost)" != "200" ]; then
		echo "Request failed. Web server responded with $@"
		exit 1
	fi
		
	echo "Seeding personnel records..."
	i=1
	if [ "$(curl -s -o /dev/null -w ''%{http_code}'' -I -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost/services/um/seed)" != "200" ]; then 
		echo "Seeding personnel records failed. Web server responded with $@"
		exit 1
	fi
	echo "Seeded Personnel Records successfully!!"

	echo "Seeding SCIF Records..."
	if [ "$(curl -s -o /dev/null -w ''%{http_code}'' -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost/services/scifmanagement/seedscifs)" != "200" ]; then
		echo "Seeding SCIF records failed. Web server responded with $@"
		exit 1
	fi
	echo "Seeded SCIF Records successfully!!"
		
}
check_prerequisites()
{

	#Check to see if we are on Windows
	if [[ ! -d "$HOME/bin" && ! -z $OS && $OS=="Windows_NT" ]]; then
		echo "Creating $HOME/bin"
		mkdir "$HOME/bin"
	fi
	
	#Get jq for windows if needed
	#https://gist.github.com/evanwill/0207876c3243bbb6863e65ec5dc3f058
	#http://gnuwin32.sourceforge.net/packages.html
	if [[ ! -z $OS && $OS=="Windows_NT" && ! -f "$HOME/bin/jq.exe" ]]; then
		echo "Fetching JSON Parser (jq)..."
		curl -#L -o "$HOME/bin/jq.exe https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe"
	fi
	
	#Get wget for windows if needed
	if [[ ! -z $OS && $OS=="Windows_NT" && ! -f "$HOME/bin/wget.exe" ]]; then
		echo "Fetching wget..."
		#curl -#L -o $HOME/bin/wget.exe https://eternallybored.org/misc/wget/1.20.3/64/wget.exe
	fi
	
	#Get bzip for windows if needed
	if [[ ! -z $OS && $OS=="Windows_NT" && ! -f "$HOME/bin/bzip2.dll" ]]; then
		echo "Fetching JSON Parser (jq)..."
		#curl -#L -o $HOME/tmp/bzip2-1.0.5-bin.zip https://ayera.dl.sourceforge.net/project/gnuwin32/bzip2/1.0.5/bzip2-1.0.5-bin.zip
	fi
	
	#Get zip for windows if needed
	if [[ ! -z $OS && $OS=="Windows_NT" && ! -f "$HOME/bin/zip.exe" ]]; then
		echo "Fetching zip..."
		#curl -#L -o $HOME/tmp/zip-3.0-bin.zip http://downloads.sourceforge.net/gnuwin32/zip-3.0-bin.zip
		#TODO: unzip to $HOME/bin
	fi
	#Get jq for debian-like distributions if needed
	if [[ -f /etc/os-release && $(sed -n 's/^ID_LIKE=//p' /etc/os-release) == 'debian' && $(which jq) == -1 ]]; then
		echo "Installing JSON Parser (jq)..."
		apt-get install -y jq
	fi
	
	#Get jq for rhel-like distributions if needed
	if [[ -f /etc/os-release && $(sed -n 's/^ID_LIKE=//p' /etc/os-release) == 'fedora' && $(which jq) == -1 ]]; then
		echo "Installing JSON Parser (jq)..."
		yum install -y jq
	fi
	
	files="accumulo/scripts/start-accumulo accumulo/scripts/seed-accumulo.sh accumulo/scripts/insertjckes.sh smtp/smtp.sh"
	for file in $files
	do
		$(dos2unix < "$file" | cmp -s - "$file" ) >&1
		if [[ "$?" -ne 0 ]]; then
			dos2unix "$file"
		fi
	done

	if [ $(stat -c "%a" httpd/htdocs/index.html) != 755 ]; then
		echo "Fixing file permissions..."
		chmod -R 755 httpd/htdocs
	fi

	STATUS=$(curl -s -o /dev/null -w ''%{http_code}'' -I -k \
	--cert httpd/certificates/Alice1stCmdSSR_cert_out.pem \
	https://localhost/)
	
	if [ "$STATUS" == "200" ]; then 
		echo "CK Frontend is running!!"
	elif [ "$STATUS" == "400" ]; then 
		echo "HTTP/1.1 400 Bad Request"
		echo "Please check the WAR file has deployed completely in jboss/deployments/"
		echo "Try running \"deploy.sh -j\""
		#exit $STATUS
	elif [ "$STATUS" == "403" ]; then 
		echo "HTTP/1.1 403 Forbidden error"
		echo "Please check contents and permissions for httpd/htdocs/"
		echo "Try running \"deploy.sh -f\""
	else
		echo "The CK stack does not appear to be running."
		echo "Please run \"docker-compose -f [ENV].yml up -d\""
		echo "(sudo may be required in some environments)"
	fi	
}
deploy_frontend()
{
	USER=$1
	PASS=$2
	BUILD=$3
	#OPTION 1: Get the WAR file from the S3 bucket and overwite the exiting
	#aws s3 cp s3://castlekeep-release/dist.tar.gz tmp/dist.tar.gz --region=us-gov-west-1

	#OPTION 2: Get the new WAR file from the NEXUS repo
	if [ -z "$BUILD" ]; then
		URL=$(curl -s -u $USER:$PASS \
		-H "Content-type: application/json" \
		-H "Accept:application/json" \
		https://nexus.di2e.net/nexus/service/local/repositories/Private_CKF_Releases/content/gov/ic/army/castlekeep/recent/ck-front-end-v2-development/ | \
		jq -r '[.data[].resourceURI | select (. | endswith(".tar.gz"))][-1]')
	else
		URL="https://nexus.di2e.net/nexus/service/local/repositories/Private_CKF_Releases/content/gov/ic/army/castlekeep/recent/ck-front-end-v2-development/recent-ck-front-end-v2-development-$BUILD.tar.gz"
	fi
	if [ -z "$URL" ]; then
		echo "Incorrect username or password"
		exit 1
	fi
	
	FILE="$(basename $URL)"
	STATUS="$(curl -s -u $USER:$PASS -o /dev/null -w ''%{http_code}'' -I -k $URL)"
	
	if [ "$STATUS" == "200" ]; then
		mkdir -p "tmp"
		curl -u "$USER:$PASS -o tmp/$FILE -# $URL";		
	elif [ "$STATUS" == "404" ]; then 
		echo "Build not found for: $URL"
		exit 1
	else
		echo "Unknown Error: $STATUS"
		exit 1
	fi

	echo "Downloading: $URL"

	echo "Deploying $FILE..."
	tar -xzf "tmp/$FILE" --checkpoint=.100 -C tmp/;
	echo ""
	rm -rf httpd/htdocs/*
	mv tmp/dist/* httpd/htdocs/
	chmod -R 755 httpd/htdocs

	echo "Successfully deployed $FILE"
	exit 0
	#TODO: Check permissions?
	#TODO: Remove tmp files
#	rm -f "tmp/$FILE"
#	rm -rf "tmp/dist"

	#Get latest build number
	#TODO: use this to verify latest
	#BUILD=$(curl -k -i -u $USERNAME -p https://jenkins.di2e.net/job/CK/job/CK%20Front-End%20v2%20Dev/lastSuccessfulBuild/api/json)
}

deploy_java()
{
	USER=$1
	PASS=$2
	BUILD=$3
	OLD_FILE=$(basename jboss/deployments/*ck-services*.war)

	#OPTION 1: Get the new WAR file from the S3 bucket and overwite the exiting
	#aws s3 cp s3://castlekeep-release/ck-services-1.0-SNAPSHOT.war jboss/deployments/ --region=us-gov-west-1
	
	#OPTION 2: Get the new WAR file from the NEXUS repo and overwite the exiting

	# 1) Try to redploy the existing file?
	if [[ -f "jboss/deployments/$OLD_FILE" && ! -f "jboss/deployments/$OLD_FILE.deployed" ]]; then
		read -p "CK $OLD_FILE does not appear to be running. Download a new WAR file? (y/n)" -n 1 -r
		echo ""
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
			if [ ! -f "jboss/deployments/$OLD_FILE" ]; then
				echo "There is no valid CK WAR file on this system. Please download a new WAR file"
				exit 1
			elif [ -f "jboss/deployments/$OLD_FILE.failed" ]; then
				rm -f "jboss/deployments/$OLD_FILE.failed"
			elif [ -f "tmp/$OLD_FILE" ]; then
				rm -f "jboss/deployments/$OLD_FILE*"
				cp "tmp/$OLD_FILE" "jboss/deployments/$OLD_FILE"
				chmod -R 755 jboss/deployments
			fi
			#Wait while backup WAR file is redeploying
			echo "Redeploying $OLD_FILE..."
			while [[ ! -f "jboss/deployments/$OLD_FILE.*" || -f "jboss/deployments/$OLD_FILE.isdeploying" || -f "jboss/deployments/$OLD_FILE.pending" ]]; do
				spinner $i
				sleep .1
				if [ -f "jboss/deployments/$OLD_FILE.failed" ]; then
					cat "jboss/deployments/$OLD_FILE.failed"
					echo "Backend deployment failed for $OLD_FILE :("
					exit 1
				fi
			done
			echo "Successfully rolled back to $OLD_FILE"
			exit 0
		elif [ ! -f "jboss/deployments/$OLD_FILE" ]; then
			echo "There is no valid CK WAR file on this system. Please download a new WAR file"
			exit 1
		else
			mv "jboss/deployments/$OLD_FILE" "tmp/$OLD_FILE"
			echo "Undeploying $OLD_FILE..."
			while [ ! -f "jboss/deployments/$OLD_FILE.undeployed" ]; do
				spinner $i
				sleep .1
			done
			echo ""
		fi
	fi
	
	#OPTION 2: Get the new WAR file from the NEXUS repo
	
	#3) Get the URL of the latest build
	if [ -z "$BUILD" ]; then
		URL=$(curl -s -u $USER:$PASS \
		-H Content-type: application/json \
		-H Accept:application/json \
		https://nexus.di2e.net/nexus/service/local/repositories/Private_CKF_Releases/content/gov/ic/army/castlekeep/recent/ck-services-development/ | \
		jq -r '[.data[].resourceURI | select (. | endswith(".war"))][-1]')
	else
		URL="https://nexus.di2e.net/nexus/service/local/repositories/Private_CKF_Releases/content/gov/ic/army/castlekeep/recent/ck-services-development/recent-ck-services-development-$BUILD.war"
	fi
	
	if [ -z "$URL" ]; then
		echo "Incorrect username or password"
		exit 1
	fi

	FILE=$("basename $URL")
	STATUS=$("curl -s -u $USER:$PASS -o /dev/null -w ''%{http_code}'' -I -k $URL")	
	if [ "$STATUS" == "200" ]; then
		mkdir -p "tmp"
		#TODO: Cleanup and merge with #4
	elif [ "$STATUS" == "404" ]; then 
		echo "Build not found for: $URL"
		exit 1
	else
		echo "Unknown Error: $STATUS"
		exit 1
	fi
	
	#4) Download the latest build if there is not one already in tmp and deploy it! (look in tmp first to save time for debugging)
	if [ ! -f "tmp/$FILE" ]; then
		echo "Downloading $URL"
		curl "-u $USER:$PASS -o tmp/$FILE -# $URL"
		cp "tmp/$FILE" "jboss/deployments/"
		chmod -R 755 jboss/deployments/$FILE
	elif [ "$FILE" == "$OLD_FILE" ]; then
		echo "Lazy redeploy for $FILE"
		rm -f "jboss/deployments/$FILE.*"
	else
		#FILE=$OLD_FILE
		cp "tmp/$FILE" "jboss/deployments/"
		chmod -R 755 "jboss/deployments/$FILE"
		#echo "Using tmp/$OLD_FILE..."
		#mv "tmp/$OLD_FILE" "jboss/deployments/"
	fi
	
	#Something went really bad if this happens... check file permission or password because the WAR file is not being read or is gone
	if [ ! -f "jboss/deployments/$FILE" ]; then
		echo "Backend deployment failed. Could not download latest build from NEXUS:("
		exit 1;
	fi
	
	#AWS & *nix often require sudo to change file ownership/permissions. GitBash on Windows localhost doesnt use sudo
	# if [ ! -z $AWS ]; then
		# chown :ckdev "jboss/deployments/*"
		# chmod 755 "jboss/deployments/*"			
	# elif [[ -z $OS && $OS=="Windows_NT" ]]; then
		# chmod 755 "jboss/deployments/*"			
	# else
		# chmod 755 "jboss/deployments/*"			
	# fi
	
	i=1
	#Wait while WAR file is deploying... where ever it came from!!
	echo ""
	echo "Deploying $FILE..."
	while [[ -f "jboss/deployments/$FILE.isdeploying" || -f "jboss/deployments/$FILE.pending" || ! -f "jboss/deployments/$FILE.failed" ]]; do
		spinner $i
		sleep .1
	done
	echo ""
	
	status=0
	#Rollback back if the deployment fails
	if [[ -f "jboss/deployments/$FILE.failed" && -f "tmp/$OLD_FILE" ]]; then
		cat "jboss/deployments/$FILE.failed"
		echo ""
		rm -f "jboss/deployments/$FILE"
		cp "tmp/$OLD_FILE" "jboss/deployments/"
		touch "jboss/deployments/$OLD_FILE.dodeploy"
		chmod 755 "jboss/deployments/$OLD_FILE"
		echo "Deployment failed... rolling back"
		status=2
	else
		echo "Rollback failed... exiting"
		echo "Please check jboss/deployments/ and tmp/"
		status=3
	fi
	
	#Wait while backup WAR file is redeploying
	while [[ ! -f "jboss/deployments/$OLD_FILE.deployed" || -f "jboss/deployments/$OLD_FILE.isdeploying" || -f "jboss/deployments/$OLD_FILE.pending" ]]; do
		spinner $i
		sleep .1
	done	
	echo ""
	
	if [ $status -eq 0 ]; then
		echo "Backend deployed successfully!!"
		# echo "Seeding Personnel Records!!"
		seed $USER $PASS;
		# curl -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost/services/um/seed
		# while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost/services/um/seed)" != "200" ]]; do 
			# spinner $i
			# sleep .1
		# done
		# echo "Seeded Personnel Records successfully!!"

		# echo "Seeding SCIF Records!!"
		# curl -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost/services/scifmanagement/seedscifs
		# while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' -k --cert httpd/certificates/Alice1stCmdSSR.p12:changeit --cert-type P12 https://localhost/services/scifmanagement/seedscifs)" != "200" ]]; do 
			# spinner $i
			# sleep .1
		# done
		# echo "Seeded SCIF Records successfully!!"
	elif [ $status -eq 2 ]; then
		echo "Rollback successful!!"
	else
		echo "Backend deployment failed :("
	fi
	
	exit $status	
	
	#Get latest build number 
	#TODO: use this to verify latest
	#BUILD=$(curl -k -i -u $USERNAME -p https://jenkins.di2e.net/job/CK/job/CK%20Services%20Dev/lastSuccessfulBuild/api/json)
	#TODO: Check to see if jboss and/or web containers are running
}


if [ -z "$1" ]; then
	usage
elif [[ "$1" == "-s" || "$1" == "--seed" ]]; then
	seed
elif [[ "$1" == "-c" || "$1" == "--check" ]]; then
	check_prerequisites
else
	echo "Enter your DI2E credentials:" 
	read -p 'Username: ' USER
	read -sp 'Password: ' PASS
	echo ""
fi

while [ "$1" != "" ]; do
    case $1 in
        -f | --frontend )       check_prerequisites
								deploy_frontend $USER $PASS $2
                                ;;
        -j | --java )    		check_prerequisites
								deploy_java $USER $PASS $2
                                ;;
        -s | --seed )    		seed
                                ;;
        -a | --all )    		deploy_frontend $USER $PASS
								deploy_java $USER $PASS
								seed
                                ;;
        -h | --help )           usage
                                exit 0
                                ;;
        -c | --check )       	check_prerequisites
                                ;;	
		''|*[!0-9]*) 			exit 0
								;;								
        * )                     usage
                                exit 1
    esac
    shift
done

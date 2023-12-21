#!/bin/bash
#----------------------------------------------------------------------------
#  Copyright (c) 2023 WSO2, LLC. http://www.wso2.org
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#----------------------------------------------------------------------------
set -o xtrace; set -e

TESTGRID_DIR=/opt/testgrid/workspace
INFRA_JSON='infra.json'

PRODUCT_REPOSITORY=$1
PRODUCT_REPOSITORY_BRANCH=$2
PRODUCT_NAME=$3
PRODUCT_VERSION=$4
GIT_USER=$5
GIT_PASS=$6
TEST_MODE=$7
PRODUCT_REPOSITORY_NAME=$(echo $PRODUCT_REPOSITORY | rev | cut -d'/' -f1 | rev | cut -d'.' -f1)
PRODUCT_REPOSITORY_PACK_DIR="$TESTGRID_DIR/$PRODUCT_REPOSITORY_NAME/distribution/target"
INT_TEST_MODULE_DIR="$TESTGRID_DIR/$PRODUCT_REPOSITORY_NAME/integration"
PRODUCT_REPO_DIR="$TESTGRID_DIR/$PRODUCT_REPOSITORY_NAME"

# CloudFormation properties
CFN_PROP_FILE="${TESTGRID_DIR}/cfn-props.properties"

JDK_TYPE=$(grep -w "JDK_TYPE" ${CFN_PROP_FILE} | cut -d"=" -f2)
PRODUCT_PACK_NAME=$(grep -w "REMOTE_PACK_NAME" ${CFN_PROP_FILE} | cut -d"=" -f2)

function log_info(){
    echo "[INFO][$(date '+%Y-%m-%d %H:%M:%S')]: $1"
}

function log_error(){
    echo "[ERROR][$(date '+%Y-%m-%d %H:%M:%S')]: $1"
    exit 1
}

function install_jdk(){
    jdk_name=$1

    mkdir -p /opt/${jdk_name}
    jdk_file=$(jq -r '.jdk[] | select ( .name == '\"${jdk_name}\"') | .file_name' ${INFRA_JSON})
    wget -q https://integration-testgrid-resources.s3.amazonaws.com/lib/jdk/$jdk_file.tar.gz
    tar -xzf "$jdk_file.tar.gz" -C /opt/${jdk_name} --strip-component=1

    export JAVA_HOME=/opt/${jdk_name}
    echo $JAVA_HOME
}

source /etc/environment

log_info "Clone Product repository"
git clone https://${GIT_USER}:${GIT_PASS}@$PRODUCT_REPOSITORY --branch $PRODUCT_REPOSITORY_BRANCH --single-branch

log_info "Exporting JDK"
install_jdk ${JDK_TYPE}

log_info "Build repository"

cd $PRODUCT_REPO_DIR
version_tags=$(grep -o "<version>.*</version>" "pom.xml")
second_version_tag=$(echo "$version_tags" | sed -n 2p)
snapshot_version=$(echo "$second_version_tag" | sed "s/<version>\(.*\)<\/version>/\1/")
version="${snapshot_version%-SNAPSHOT}"
last_number=$(echo "$version" | grep -oE '[0-9]+$')
if ((last_number > 0)); then
    decremented_version="${version%$last_number*}$((last_number - 1))"
else
    decremented_version=${PRODUCT_VERSION}
fi

NEW_PRODUCT_PACK_NAME="${PRODUCT_NAME}-${decremented_version}"

# Fetch and checkout to the tag of the previous version
git fetch --tags origin v${decremented_version}
git checkout v${decremented_version}

mvn clean install -Dmaven.test.skip=true -Dhttp.keepAlive=true -Dmaven.wagon.http.pool=false -Dmaven.wagon.http.timeout=60000 -Dmaven.wagon.http.retryHandler.count=3
cd -

mkdir -p $PRODUCT_REPOSITORY_PACK_DIR
log_info "Copying product pack to Repository"
[ -f $TESTGRID_DIR/$PRODUCT_NAME-$PRODUCT_VERSION*.zip ] && rm -f $TESTGRID_DIR/$PRODUCT_NAME-$PRODUCT_VERSION*.zip
cd $TESTGRID_DIR && mv $PRODUCT_PACK_NAME $PRODUCT_NAME-$decremented_version && zip -qr $PRODUCT_NAME-$decremented_version.zip $PRODUCT_NAME-$decremented_version
mv $TESTGRID_DIR/$PRODUCT_NAME-$decremented_version.zip $PRODUCT_REPOSITORY_PACK_DIR/.

log_info "install pack into local maven Repository"
mvn install:install-file -Dfile=$PRODUCT_REPOSITORY_PACK_DIR/$PRODUCT_NAME-$decremented_version.zip -DgroupId=org.wso2.ei -DartifactId=wso2mi -Dversion=$decremented_version -Dpackaging=zip --file=$PRODUCT_REPOSITORY_PACK_DIR/../pom.xml 
cd $INT_TEST_MODULE_DIR  && mvn clean install -fae -B -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn -DskipBenchMarkTest=true -Dhttp.keepAlive=false -Dmaven.wagon.http.pool=false

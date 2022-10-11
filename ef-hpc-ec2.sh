#!/bin/sh
EF_STACK_NAME=$1
NO_VALUE="N/A"
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -H "X-aws-ec2-metadata-token: ${TOKEN}" -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/\(.*\)[a-z]/\1/';)
SSM_ROLE_ARN=$NO_VALUE
PC_ROLE_ARN=$NO_VALUE
S3_ROLE_ARN=$NO_VALUE
BUCKET=$NO_VALUE
EF_BUNDLE=$NO_VALUE

EFNOBODY_PWD=$NO_VALUE
EFADMIN_PWD=$NO_VALUE
EFUSER_NAME=$NO_VALUE
EFUSER_PWD=$NO_VALUE

function escape_arn() {
  echo $1 | sed 's/\//\\\//g';
}

function get_secret() {
  local _secret_id=$1
  
  aws --region $AWS_REGION secretsmanager get-secret-value --secret-id $_secret_id | jq '.SecretString' | sed 's/"//g';
}

function get_param() {
  local _param_name=$1
  aws --region $AWS_REGION ssm get-parameter --name $_param_name | jq '.Parameter | .Value' | sed 's/"//g'
}

function retrieve_params() {
  EFNOBODY_PWD=$(get_secret ${EF_STACK_NAME}-EFNobodyPassword)
  EFADMIN_PWD=$(get_secret ${EF_STACK_NAME}-EFAdminPassword)
  EFUSER_PWD=$(get_secret ${EF_STACK_NAME}-EFUserPassword)
  EFUSER_NAME=$(get_param ${EF_STACK_NAME}-HPCCEFUserName)
  EF_BUNDLE=$(get_param ${EF_STACK_NAME}-HPCCEFBundle)
  SSM_ROLE_ARN=$(get_param ${EF_STACK_NAME}-HPCCEFSSMRoleArn)
  PC_ROLE_ARN=$(get_param ${EF_STACK_NAME}-HPCCEFParallelClusterRoleArn)
  S3_ROLE_ARN=$(get_param ${EF_STACK_NAME}-HPCCEFS3RoleArn)
  BUCKET=$(get_param ${EF_STACK_NAME}-HPCCEFBucketArn)
}

function install_requirements() {
    # prerequisites
    amazon-linux-extras enable corretto8
    yum install -y sudo passwd tar less wget vim nano tree curl zip unzip expect htop file python3 python3-pip java-1.8.0-amazon-corretto.x86_64 hostname jq iptables-services

    # Node, required by ParallelCluster 3
    curl -sL https://rpm.nodesource.com/setup_16.x | bash -
    yum install -y nodejs

    # ParallelCluster 3
    pip3 install --upgrade pip
    pip3 install aws-parallelcluster==3.0.0
    pip3 install aws-parallelcluster-awsbatch-cli==1.0.0

    # AWS CLI
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    ./aws/install

    # AWS Session Manager
    curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
    yum install -y session-manager-plugin.rpm
}

function create_users() {
  # User running portal
  useradd efnobody
  echo -e "$EFNOBODY_PWD\n$EFNOBODY_PWD" | passwd efnobody

  # Portal Admin
  useradd efadmin
  echo -e "$EFADMIN_PWD\n$EFADMIN_PWD" | passwd efadmin

  # Portal User
  useradd $EFUSER_NAME
  echo -e "$EFUSER_PWD\n$EFUSER_PWD" | passwd $EFUSER_NAME
}

function update_ef_install_config(){
  sed -i  's/.*hpc.aws.region.*/'"hpc.aws.region = ${AWS_REGION}"'/g' ./efinstall.config
  local _escaped_arn=$(escape_arn $SSM_ROLE_ARN)
  sed -i  's/.*hpc.ssm.role.arn.*/'"hpc.ssm.role.arn = ${_escaped_arn}"'/g' ./efinstall.config
  _escaped_arn=$(escape_arn $S3_ROLE_ARN)
  sed -i  's/.*hpc.s3.role.arn.*/'"hpc.s3.role.arn = ${_escaped_arn}"'/g' ./efinstall.config
  _escaped_arn=$(escape_arn $PC_ROLE_ARN)
  sed -i  's/.*hpc.pcluster.role.arn.*/'"hpc.pcluster.role.arn = ${_escaped_arn}"'/g' ./efinstall.config
  _escaped_arn=$(escape_arn $BUCKET)
  sed -i  's/.*hpc.aws.bucket.arn.*/'"hpc.aws.bucket.arn = ${_escaped_arn}"'/g' ./efinstall.config
}

function configure_redirect() {
    local -r __source=$1
    local -r __dest=$2
    local -r __protocol=$3

    iptables -A PREROUTING -t nat -i eth0 -p ${__protocol} --dport ${__dest} -j REDIRECT --to-port  ${__source}
    iptables -I OUTPUT     -t nat -o lo   -p ${__protocol} --dport ${__dest} -j REDIRECT --to-ports ${__source}

    service iptables save
}

function install_enginframe() {
  # Retrieve enginframe bundle
  aws s3 cp $EF_BUNDLE .
  aws s3 cp s3://bucket0081/efinstall.config ./efinstall.config

  https_port=$(grep -Po '^kernel.tomcat.https.port.*=[^0-9]*\K[0-9]+' ./efinstall.config)
  configure_redirect ${https_port:=8443} 443 tcp

  update_ef_install_config

  # Install enginframe
  EF_BINARY=$(basename $EF_BUNDLE)
  java -jar $EF_BINARY --text --batch -f ./efinstall.config

  # Update hpc conf to enable InstanceProfile
  echo "#USE INSTANCE PROFILE" >> /opt/nice/enginframe/conf/plugins/hpc/hpc.efconf
  echo "HPCC_USE_INSTANCE_PROFILE=true" >> /opt/nice/enginframe/conf/plugins/hpc/hpc.efconf
}

function main() {
  install_requirements
  retrieve_params
  create_users
  install_enginframe
}

main "$@"

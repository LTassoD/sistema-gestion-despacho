#!/bin/bash
# setup-despachos.sh - Despliegue completo infraestructura AWS
# EP2 - Sistema de Gestión de Despachos
set -euo pipefail

REGION="us-east-1"
SG_WEB_NAME="despachos-web"
SG_APP_NAME="despachos-app"
SG_DB_NAME="despachos-db"
PROFILE="LabInstanceProfile"
KEY_NAME="vockey"

cleanup_vpcs() {
  echo "=== LIMPIANDO VPCs HUERFANAS ==="
  for vpc in $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=despachos-vpc" --query "Vpcs[*].VpcId" --output text --region "$REGION"); do
    echo "Limpiando VPC: $vpc"
    # Terminar instancias
    for id in $(aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc" --query "Reservations[*].Instances[*].InstanceId" --output text --region "$REGION"); do
      aws ec2 terminate-instances --instance-ids "$id" --region "$REGION" 2>/dev/null || true
    done
    # Eliminar security groups (sin el default)
    for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region "$REGION"); do
      aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
    done
    # Eliminar subnets
    for sn in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query "Subnets[*].SubnetId" --output text --region "$REGION"); do
      aws ec2 delete-subnet --subnet-id "$sn" --region "$REGION" 2>/dev/null || true
    done
    # Eliminar route tables (sin la principal)
    for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query "RouteTables[?Associations[?Main!=true]].RouteTableId" --output text --region "$REGION"); do
      aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
    done
    # Desasociar y eliminar IGW
    for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query "InternetGateways[*].InternetGatewayId" --output text --region "$REGION"); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
    done
    # Eliminar NAT GW
    for nat in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query "NatGateways[*].NatGatewayId" --output text --region "$REGION"); do
      aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" 2>/dev/null || true
    done
    # Liberar EIPs
    for eip in $(aws ec2 describe-addresses --filters "Name=domain,Values=vpc" --query "Addresses[?InstanceId==null].AllocationId" --output text --region "$REGION"); do
      aws ec2 release-address --allocation-id "$eip" --region "$REGION" 2>/dev/null || true
    done
    # Eliminar VPC
    aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null || echo "  VPC $vpc no se pudo eliminar (puede tener recursos residuales)"
  done
  echo "Limpieza completa."
}

# === LIMPIEZA PREVIA ===
cleanup_vpcs

# === VPC ===
echo "=== VPC ==="
VPC_ID=$(aws ec2 create-vpc --cidr-block "10.0.0.0/16" --query "Vpc.VpcId" --output text --region "$REGION")
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$REGION"
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=despachos-vpc --region "$REGION"
echo "VPC: $VPC_ID"

# === IGW ===
echo "=== IGW ==="
IGW_ID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text --region "$REGION")
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo "IGW: $IGW_ID"

# === SUBNETS ===
echo "=== SUBNETS ==="
SN_PUB=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.0.1.0/24" --query "Subnet.SubnetId" --output text --region "$REGION")
aws ec2 modify-subnet-attribute --subnet-id "$SN_PUB" --map-public-ip-on-launch --region "$REGION"
aws ec2 create-tags --resources "$SN_PUB" --tags Key=Name,Value=despachos-subnet-public --region "$REGION"
echo "Public subnet: $SN_PUB"

SN_APP=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.0.2.0/24" --query "Subnet.SubnetId" --output text --region "$REGION")
aws ec2 create-tags --resources "$SN_APP" --tags Key=Name,Value=despachos-subnet-app --region "$REGION"
echo "App subnet: $SN_APP"

SN_DB=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.0.3.0/24" --query "Subnet.SubnetId" --output text --region "$REGION")
aws ec2 create-tags --resources "$SN_DB" --tags Key=Name,Value=despachos-subnet-db --region "$REGION"
echo "DB subnet: $SN_DB"

# === ROUTE PUBLIC ===
echo "=== ROUTE PUBLIC ==="
RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query "RouteTable.RouteTableId" --output text --region "$REGION")
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" --region "$REGION" 2>/dev/null || true
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$SN_PUB" --region "$REGION"
echo "Public RT: $RT_PUB"

# === NAT GATEWAY ===
echo "=== NAT GATEWAY ==="
EIP_NAT=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text --region "$REGION")
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$SN_PUB" --allocation-id "$EIP_NAT" --query "NatGateway.NatGatewayId" --output text --region "$REGION")
echo "Esperando NAT (2 min)..."
sleep 120

# === ROUTES PRIVADAS ===
echo "=== ROUTES PRIVADAS ==="
for SID in "$SN_APP" "$SN_DB"; do
  RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query "RouteTable.RouteTableId" --output text --region "$REGION")
  aws ec2 create-route --route-table-id "$RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID" --region "$REGION" 2>/dev/null || true
  aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$SID" --region "$REGION"
  echo "Private RT para $SID: $RT"
done

# === SECURITY GROUPS ===
echo "=== SECURITY GROUPS ==="
SG_WEB=$(aws ec2 create-security-group --group-name "$SG_WEB_NAME" --description "SG Frontend" --vpc-id "$VPC_ID" --query "GroupId" --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" --protocol tcp --port 80 --cidr "0.0.0.0/0" --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" --protocol tcp --port 22 --cidr "0.0.0.0/0" --region "$REGION"
echo "Web SG: $SG_WEB ($SG_WEB_NAME)"

SG_APP=$(aws ec2 create-security-group --group-name "$SG_APP_NAME" --description "SG Backends" --vpc-id "$VPC_ID" --query "GroupId" --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 8080 --source-group "$SG_WEB" --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 8081 --source-group "$SG_WEB" --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 22 --source-group "$SG_WEB" --region "$REGION"
echo "App SG: $SG_APP ($SG_APP_NAME)"

SG_DB=$(aws ec2 create-security-group --group-name "$SG_DB_NAME" --description "SG MySQL" --vpc-id "$VPC_ID" --query "GroupId" --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" --protocol tcp --port 3306 --source-group "$SG_APP" --region "$REGION"
echo "DB SG: $SG_DB ($SG_DB_NAME)"

# === INSTANCIAS EC2 ===
echo "=== INSTANCIAS EC2 ==="
AMI=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 --query "Parameters[0].Value" --output text --region "$REGION")
echo "AMI: $AMI"

ID_WEB=$(aws ec2 run-instances \
  --image-id "$AMI" --instance-type t3.micro \
  --subnet-id "$SN_PUB" --security-group-ids "$SG_WEB" \
  --iam-instance-profile Name="$PROFILE" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-frontend}]' \
  --query "Instances[0].InstanceId" --output text --region "$REGION")
echo "Web EC2: $ID_WEB"

ID_APP=$(aws ec2 run-instances \
  --image-id "$AMI" --instance-type t3.micro \
  --subnet-id "$SN_APP" --security-group-ids "$SG_APP" \
  --iam-instance-profile Name="$PROFILE" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-backend}]' \
  --query "Instances[0].InstanceId" --output text --region "$REGION")
echo "App EC2: $ID_APP"

ID_DB=$(aws ec2 run-instances \
  --image-id "$AMI" --instance-type t3.micro \
  --subnet-id "$SN_DB" --security-group-ids "$SG_DB" \
  --iam-instance-profile Name="$PROFILE" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-db}]' \
  --query "Instances[0].InstanceId" --output text --region "$REGION")
echo "DB EC2: $ID_DB"

echo "Esperando instancias..."
aws ec2 wait instance-running --instance-ids "$ID_WEB" "$ID_APP" "$ID_DB" --region "$REGION"

EIP_WEB=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text --region "$REGION")
EIP_WEB_IP=$(aws ec2 describe-addresses --allocation-ids "$EIP_WEB" --query "Addresses[0].PublicIp" --output text --region "$REGION")
aws ec2 associate-address --allocation-id "$EIP_WEB" --instance-id "$ID_WEB" --region "$REGION"

IP_APP=$(aws ec2 describe-instances --instance-ids "$ID_APP" --query "Reservations[0].Instances[0].PrivateIpAddress" --output text --region "$REGION")
IP_DB=$(aws ec2 describe-instances --instance-ids "$ID_DB" --query "Reservations[0].Instances[0].PrivateIpAddress" --output text --region "$REGION")

# === SSM: INSTALAR DOCKER Y DESPLEGAR ===
echo "=== ESPERANDO SSM (3 min) ==="
sleep 180

echo "=== INSTALAR DOCKER ==="
aws ssm send-command \
  --instance-ids "$ID_WEB" "$ID_APP" "$ID_DB" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo yum update -y","sudo yum install -y docker git","sudo systemctl enable docker","sudo systemctl start docker","sudo usermod -aG docker ec2-user"]' \
  --region "$REGION" --output text

echo "Esperando instalacion Docker (2 min)..."
sleep 120

echo "=== DESPLEGAR MYSQL ==="
aws ssm send-command \
  --instance-ids "$ID_DB" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo docker run -d --name mysql-despachos -p 3306:3306 -e MYSQL_ROOT_PASSWORD=admin123 -e MYSQL_DATABASE=despachos_db -v dbdata:/var/lib/mysql mysql:8"]' \
  --region "$REGION" --output text

echo "=== DESPLEGAR BACKENDS ==="
aws ssm send-command \
  --instance-ids "$ID_APP" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"sudo docker run -d --name backend-ventas -p 8080:8080 -e DB_ENDPOINT=$IP_DB -e DB_PORT=3306 -e DB_NAME=despachos_db -e DB_USERNAME=root -e DB_PASSWORD=admin123 ltassod/tienda-backend-ventas:latest\",\"sudo docker run -d --name backend-despachos -p 8081:8081 -e DB_ENDPOINT=$IP_DB -e DB_PORT=3306 -e DB_NAME=despachos_db -e DB_USERNAME=root -e DB_PASSWORD=admin123 ltassod/tienda-backend-despachos:latest\"]" \
  --region "$REGION" --output text

echo "=== DESPLEGAR FRONTEND ==="
aws ssm send-command \
  --instance-ids "$ID_WEB" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo docker run -d --name frontend-despachos -p 80:80 ltassod/tienda-frontend-despacho:latest"]' \
  --region "$REGION" --output text

# === OUTPUT ===
echo ""
echo "============================================"
echo "  IP Frontend: http://$EIP_WEB_IP"
echo "  ID Web: $ID_WEB"
echo "  ID App: $ID_APP"
echo "  ID DB:  $ID_DB"
echo "  IP App Privada: $IP_APP"
echo "  IP DB Privada: $IP_DB"
echo "============================================"
echo ""
echo "Actualiza los workflows con:"
echo "  EC2_FRONTEND=$ID_WEB"
echo "  EC2_BACKEND=$ID_APP"
echo "  EC2_DB=$ID_DB"
echo "  DB_HOST=$IP_DB"
echo "============================================"

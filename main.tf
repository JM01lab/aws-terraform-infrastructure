#Terraform
 
#main.tf

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configuration du Fournisseur (Provider)
provider "aws" {
  region = "us-east-1" # REGION CIBLE
}
# Data Source pour les Zones de Disponibilité (AZ)
data "aws_availability_zones" "available" {
  state = "available"


#vpc.tf (Subnets)

# 1. VPC (Réseau Virtuel)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true         # Autorise les requête DNS
  enable_dns_hostnames = true         # Donne un nom d’hôte aux instances

  tags = {
    Name = "MonProjet-VPC"
  }
}

# 2. Subnets Publics (2 Subnets dans 2 AZ)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # IP publique pour les ALB et NAT GW

  tags = {
    Name = "MonProjet-Public-Subnet-${count.index + 1}"
  }
}

# 3. Subnets Privés (2 Subnets pour les instances EC2)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 2) # 10.0.2.0/24 et 10.0.3.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false # Pas d'IP publique pour les serveurs internes

  tags = {
    Name = "MonProjet-Private-Subnet-${count.index + 1}"
  }
}

#4. Internet Gateway (IGW - Pour l'accès Internet)
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "MonProjet-IGW"
  }
}

# 5. Elastic IP (EIP) pour le NAT Gateway
resource "aws_eip" "nat" {
  count = 1

}
# 6. NAT Gateway (Permet aux instances privées de sortir vers Internet)
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id # Place le NAT GW dans un Subnet Public
  depends_on    = [aws_internet_gateway.gw] # Doit attendre l'IGW

  tags = {
    Name = "MonProjet-NAT-GW"
  }
}

resource "aws_eip" "nat" {
  vpc = true # Ligne problématique!
  # ...
}

resource "aws_eip" "nat" {
  # La ligne 'vpc = true' a été supprimée, 
  # car l'allocation dans le VPC est désormais implicite ou gérée par d'autres arguments.
  depends_on = [aws_internet_gateway.gw] 
}

#7. Table de Routage Publique (Vers Internet)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "MonProjet-Public-RT"
  }
}

# 8. Association des Subnets Publics à la Route Table Publique
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 9. Table de Routage Privée (Vers NAT GW)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = {
    Name = "MonProjet-Private-RT"
  }
}

# 10. Association des Subnets Privés à la Route Table Privée
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
route_table_id = aws_route_table.private.id
}


# security.tf

# 1. Security Group pour l'ALB (ALB SG)
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg-projet"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = aws_vpc.main.id

  # Trafic entrant (Ingress)
  ingress {
    description = "HTTP de partout"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Ou une plage d'IP spécifique si nécessaire
  }

  # Trafic sortant (Egress - Tout autoriser)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ALB-SG-Projet"
  }
}

# 2. Security Group pour les EC2 (EC2 SG)
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg-projet"
  description = "Allow ALB and SSH traffic to EC2 instances"
  vpc_id      = aws_vpc.main.id

  # Trafic entrant (Ingress) : Autoriser le HTTP (Port 80) uniquement depuis l'ALB
  ingress {
    description     = "HTTP de ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Source: L'ALB SG
  }

  # Trafic entrant (Ingress) : Autoriser SSH (Port 22) depuis votre IP (0.0.0.0/0 pour l'exemple)
  ingress {
    description = "SSH for administration"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Idéalement, remplacez par votre IP publique /32
  }

  # Trafic sortant (Egress - Tout autoriser)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "EC2-SG-Projet"
  }
}


#alb.tf

# 1. Création de l’Application Load Balancer (ALB)
resource "aws_lb" "application_lb" {
  name               = "mon-alb-asg-projet"
  internal           = false 
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id] 

  # Place l'ALB dans les subnets publics 
  subnets = [
    aws_subnet.public[0].id,
    aws_subnet.public[1].id
  ]

  tags = {
    Name = "ALB-Projet"
  }

}
# 2. Création du Target Group (Groupe Cible)
resource "aws_lb_target_group" "target_group" {
  name     = "mon-tg-asg-projet"
  port     = 80 
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"        
    protocol            = "HTTP"
    matcher             = "200"      
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "TargetGroup-Projet"
  }
}

# 3. Listener (Écouteur)
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.application_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }
}


# launch_template.tf

# DATA BLOCK : Trouve l'AMI Amazon Linux 2 (AL2) la plus récente pour US-East-1
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"] 

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"] 
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# DATA BLOCK : Script de démarrage (User Data) pour installer Apache
data "template_file" "user_data_template" {
  template = <<-EOF
              #!/bin/bash
              yum update -y
              yum install httpd -y
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Serveur lance par Terraform dans US-EAST-1</h1>" > /var/www/html/index.html
              EOF
}

# 1. Launch Template (Modèle de lancement des instances)
resource "aws_launch_template" "asg_launch_template" {
  name_prefix   = "mon-asg-lt"
  image_id      = data.aws_ami.amazon_linux_2.id # AMI Dynamique (corrigé)
  instance_type = "t3.micro"

  # Clé SSH (CORRIGÉE)
  key_name      = "votre_clé_ssh" 

  network_interfaces {
    associate_public_ip_address = false 
    security_groups             = [aws_security_group.ec2_sg.id] 
  }

  user_data = base64encode(data.template_file.user_data_template.rendered)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Instance-ASG-Projet"
    }
  }
}


# asg.tf

# 2. Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "mon_asg" {
  name                      = "Mon-ASG-Projet"
  max_size                  = 2  
  min_size                  = 1  
  desired_capacity          = 1  

  launch_template {
    id      = aws_launch_template.asg_launch_template.id
    version = "$Latest"
  }

  # Place les instances dans les subnets PRIVÉS
  vpc_zone_identifier = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id
  ]

  # Lie l'ASG au Target Group de l'ALB
  target_group_arns = [aws_lb_target_group.target_group.arn]

  tag {
    key                 = "Name"
    value               = "ASG-Instance"
    propagate_at_launch = true 
  }
}

# 3. Scaling Policy (Pour l'auto-scaling)
resource "aws_autoscaling_policy" "cpu_scale_up" {
  name                   = "cpu-scale-up-policy"
  autoscaling_group_name = aws_autoscaling_group.mon_asg.name

  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0 
  }
}

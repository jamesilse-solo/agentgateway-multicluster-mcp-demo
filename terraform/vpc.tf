resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name       = "${var.cluster_name_prefix}-vpc"
    team       = "field-engineering"
    created_by = "solo-field"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name       = "${var.cluster_name_prefix}-igw"
    team       = "field-engineering"
    created_by = "solo-field"
  }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name_prefix}-public-${local.azs[count.index]}"
    team                     = "field-engineering"
    created_by               = "solo-field"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.cluster_name_prefix}-private-${local.azs[count.index]}"
    team                              = "field-engineering"
    created_by                        = "solo-field"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name       = "${var.cluster_name_prefix}-public-rt"
    team       = "field-engineering"
    created_by = "solo-field"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = length(local.azs)

  domain = "vpc"

  tags = {
    Name       = "${var.cluster_name_prefix}-nat-eip-${count.index + 1}"
    team       = "field-engineering"
    created_by = "solo-field"
  }
}

resource "aws_nat_gateway" "main" {
  count = length(local.azs)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name       = "${var.cluster_name_prefix}-nat-${count.index + 1}"
    team       = "field-engineering"
    created_by = "solo-field"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name       = "${var.cluster_name_prefix}-private-rt-${count.index + 1}"
    team       = "field-engineering"
    created_by = "solo-field"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

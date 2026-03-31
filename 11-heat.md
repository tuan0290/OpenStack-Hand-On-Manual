# Cài đặt Orchestration Service (Heat)

> Heat cho phép tạo và quản lý toàn bộ infrastructure bằng **template YAML** thay vì chạy từng lệnh thủ công.
> Tương tự AWS CloudFormation hoặc Terraform nhưng native với OpenStack.

## Heat là gì?

```
Không có Heat:                    Có Heat:
─────────────                     ─────────
openstack network create ...      openstack stack create \
openstack subnet create ...         --template my-app.yaml \
openstack router create ...         my-stack
openstack router add subnet ...
openstack security group create ...
openstack server create ...       → Heat tự động tạo tất cả
openstack floating ip create ...    theo đúng thứ tự dependency
openstack server add floating ip...
(8 lệnh, dễ sai thứ tự)          (1 lệnh, idempotent)
```

**Use case thực tế:**
- Deploy ứng dụng multi-tier (web + app + db)
- Auto-scaling group
- Disaster recovery - tái tạo môi trường từ template
- Dev/Test environment provisioning

## Mục lục

1. [Cài đặt trên Controller](#1-cài-đặt-trên-controller)
2. [Kiểm tra](#2-kiểm-tra)
3. [Lab: Tạo stack đầu tiên](#3-lab-tạo-stack-đầu-tiên)

---

## 1. Cài đặt trên Controller

> Thực hiện trên node **controller**

### 1.1 Tạo database

```bash
mysql -u root -pWelcome123
```

```sql
CREATE DATABASE heat;
CREATE USER 'heat'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost';
CREATE USER 'heat'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 1.2 Tạo user, service và endpoint

```bash
source ~/admin-openrc
```

Tạo user heat:

```bash
openstack user create --domain default --password Welcome123 heat
openstack role add --project service --user heat admin
```

Tạo 2 service entity (heat và heat-cfn):

```bash
openstack service create --name heat \
  --description "Orchestration" orchestration

openstack service create --name heat-cfn \
  --description "Orchestration" cloudformation
```

Tạo endpoints cho heat (port 8004):

```bash
openstack endpoint create --region RegionOne \
  orchestration public http://controller:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  orchestration internal http://controller:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  orchestration admin http://controller:8004/v1/%\(tenant_id\)s
```

Tạo endpoints cho heat-cfn (port 8000):

```bash
openstack endpoint create --region RegionOne \
  cloudformation public http://controller:8000/v1
openstack endpoint create --region RegionOne \
  cloudformation internal http://controller:8000/v1
openstack endpoint create --region RegionOne \
  cloudformation admin http://controller:8000/v1
```

### 1.3 Tạo Heat domain và roles trong Keystone

Heat cần domain riêng để quản lý user/project cho stack:

```bash
# Tạo heat domain
openstack domain create --description "Stack projects and users" heat

# Tạo heat_domain_admin user
openstack user create --domain heat --password Welcome123 heat_domain_admin

# Gán role admin cho heat_domain_admin trong heat domain
openstack role add --domain heat --user-domain heat --user heat_domain_admin admin

# Tạo role heat_stack_owner (user được phép tạo stack)
openstack role create heat_stack_owner

# Gán heat_stack_owner cho user demo
openstack role add --project demo --user demo heat_stack_owner

# Tạo role heat_stack_user (user được Heat tự động tạo khi deploy stack)
openstack role create heat_stack_user
```

> `heat_stack_owner`: user có thể tạo/quản lý stack.
> `heat_stack_user`: user được Heat tạo tự động bên trong stack, quyền hạn chế.

### 1.4 Cài đặt package

```bash
apt install -y heat-api heat-api-cfn heat-engine
```

### 1.5 Cấu hình Heat

Sao lưu file cấu hình gốc:

```bash
cp /etc/heat/heat.conf /etc/heat/heat.conf.orig
```

Sửa file `/etc/heat/heat.conf`:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://heat:Welcome123@controller/heat
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
heat_metadata_server_url = http://controller:8000
heat_waitcondition_server_url = http://controller:8000/v1/waitcondition
stack_domain_admin = heat_domain_admin
stack_domain_admin_password = Welcome123
stack_user_domain_name = heat
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
www_authenticate_uri = http://controller:5000
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = heat
password = Welcome123
```

Trong section `[ec2authtoken]`:

```ini
[ec2authtoken]
auth_url = http://controller:5000
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = heat
password = Welcome123
```

Trong section `[trustee]`:

```ini
[trustee]
auth_type = password
auth_url = http://controller:5000
username = heat
password = Welcome123
user_domain_name = Default
```

Trong section `[clients_keystone]`:

```ini
[clients_keystone]
auth_uri = http://controller:5000
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/heat/tmp
```

### 1.6 Đồng bộ database

```bash
su -s /bin/sh -c "heat-manage db_sync" heat
```

> Bỏ qua deprecation warning nếu có.

### 1.7 Khởi động service

> Trên Ubuntu 24.04 (Flamingo), `heat-api` và `heat-api-cfn` chạy qua Apache. Chỉ `heat-engine` có systemd service riêng.

> **Lưu ý:** Apache config mặc định trỏ đến `/usr/bin/heat-api` nhưng file WSGI đúng là `/usr/bin/heat-wsgi-api`. Cần sửa trước khi restart:

```bash
sed -i 's|WSGIScriptAlias / /usr/bin/heat-api|WSGIScriptAlias / /usr/bin/heat-wsgi-api|' \
  /etc/apache2/sites-enabled/heat-api.conf

sed -i 's|WSGIScriptAlias / /usr/bin/heat-api-cfn|WSGIScriptAlias / /usr/bin/heat-wsgi-api-cfn|' \
  /etc/apache2/sites-enabled/heat-api-cfn.conf
```

```bash
systemctl restart apache2
systemctl restart heat-engine
systemctl enable heat-engine
```

---

## 2. Kiểm tra

```bash
source ~/admin-openrc

openstack orchestration service list
```

Kết quả mong đợi:

```
+------------+-------------+------+--------+----------------------------+
| hostname   | binary      | engine_id | status | updated_at               |
+------------+-------------+------+--------+----------------------------+
| controller | heat-engine | xxx  | up     | 2025-10-01T10:00:00.000000 |
+------------+-------------+------+--------+----------------------------+
```

### Enable Heat Dashboard trên Horizon

```bash
apt install -y python3-heat-dashboard

cd /usr/share/openstack-dashboard
python3 manage.py compress
python3 manage.py collectstatic --noinput
systemctl reload apache2
```

Sau khi reload, vào Horizon → **Project → Orchestration** sẽ thấy:
- **Stacks**: quản lý stack
- **Template Generator**: tạo template bằng GUI
- **Resource Types**: xem tất cả resource type Heat hỗ trợ

---

## 3. Lab: Tạo stack đầu tiên

### 3.1 Template cơ bản - tạo 1 instance

Tạo file `~/lab-simple.yaml`:

```yaml
heat_template_version: 2021-04-16

description: Lab Heat - Tạo 1 instance đơn giản

parameters:
  image_name:
    type: string
    default: cirros
    description: Tên image để boot
  flavor_name:
    type: string
    default: m1.tiny
    description: Flavor của instance
  network_name:
    type: string
    default: selfservice-net
    description: Network để attach instance

resources:
  my_instance:
    type: OS::Nova::Server
    properties:
      name: heat-test-vm
      image: { get_param: image_name }
      flavor: { get_param: flavor_name }
      networks:
        - network: { get_param: network_name }

outputs:
  instance_ip:
    description: IP của instance
    value: { get_attr: [my_instance, first_address] }
  instance_id:
    description: UUID của instance
    value: { get_resource: my_instance }
```

Tạo stack:

```bash
source ~/demo-openrc

openstack stack create \
  --template ~/lab-simple.yaml \
  lab-simple-stack

# Theo dõi trạng thái
openstack stack list
watch openstack stack show lab-simple-stack -f value -c stack_status
```

Kết quả mong đợi: `CREATE_COMPLETE`

Xem output:

```bash
openstack stack output show lab-simple-stack instance_ip
openstack stack output show lab-simple-stack instance_id
```

### 3.2 Template nâng cao - network + security group + floating IP

Tạo file `~/lab-full.yaml`:

```yaml
heat_template_version: 2021-04-16

description: Lab Heat - Full stack với network, security group, floating IP

parameters:
  key_name:
    type: string
    default: demo-key
  image:
    type: string
    default: cirros
  flavor:
    type: string
    default: m1.tiny
  public_net:
    type: string
    default: provider-net
    description: Provider network cho floating IP

resources:

  # Security Group
  web_sg:
    type: OS::Neutron::SecurityGroup
    properties:
      name: heat-web-sg
      rules:
        - protocol: icmp
        - protocol: tcp
          port_range_min: 22
          port_range_max: 22
        - protocol: tcp
          port_range_min: 80
          port_range_max: 80

  # Private Network
  private_net:
    type: OS::Neutron::Net
    properties:
      name: heat-private-net

  private_subnet:
    type: OS::Neutron::Subnet
    properties:
      network: { get_resource: private_net }
      cidr: 10.20.30.0/24
      gateway_ip: 10.20.30.1
      dns_nameservers: [8.8.8.8]

  # Router
  router:
    type: OS::Neutron::Router
    properties:
      name: heat-router
      external_gateway_info:
        network: { get_param: public_net }

  router_interface:
    type: OS::Neutron::RouterInterface
    properties:
      router: { get_resource: router }
      subnet: { get_resource: private_subnet }

  # Instance
  web_server:
    type: OS::Nova::Server
    properties:
      name: heat-web-server
      image: { get_param: image }
      flavor: { get_param: flavor }
      key_name: { get_param: key_name }
      security_groups:
        - { get_resource: web_sg }
      networks:
        - network: { get_resource: private_net }

  # Floating IP
  floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network: { get_param: public_net }

  floating_ip_assoc:
    type: OS::Neutron::FloatingIPAssociation
    properties:
      floatingip_id: { get_resource: floating_ip }
      port_id: { get_attr: [web_server, addresses, { get_resource: private_net }, 0, port] }

outputs:
  private_ip:
    value: { get_attr: [web_server, first_address] }
  floating_ip:
    value: { get_attr: [floating_ip, floating_ip_address] }
  ssh_command:
    value:
      str_replace:
        template: ssh cirros@FIP
        params:
          FIP: { get_attr: [floating_ip, floating_ip_address] }
```

Tạo stack:

```bash
openstack stack create \
  --template ~/lab-full.yaml \
  lab-full-stack

watch openstack stack show lab-full-stack -f value -c stack_status
```

Xem kết quả:

```bash
openstack stack output list lab-full-stack
openstack stack output show lab-full-stack floating_ip
openstack stack output show lab-full-stack ssh_command
```

### 3.3 Các lệnh quản lý stack

```bash
# Liệt kê stack
openstack stack list

# Xem chi tiết
openstack stack show lab-full-stack

# Xem resources trong stack
openstack stack resource list lab-full-stack

# Xem events (lịch sử tạo)
openstack stack event list lab-full-stack

# Update stack (thay đổi template)
openstack stack update --template ~/lab-full.yaml lab-full-stack

# Xóa stack (xóa tất cả resources)
openstack stack delete lab-full-stack
openstack stack delete lab-simple-stack
```

---

Trước: [10-swift.md](10-swift.md) | Tiếp theo: [12-octavia.md](12-octavia.md)

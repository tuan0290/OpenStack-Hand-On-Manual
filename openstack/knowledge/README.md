# Knowledge Base - OpenStack Flamingo

Tài liệu tìm hiểu sâu về từng thành phần OpenStack đã cài đặt.

## Danh sách

### Môi trường (01-environment-prepare)
| File | Nội dung |
|---|---|
| [01-mariadb.md](01-mariadb.md) | MariaDB - database backend cho tất cả service |
| [02-rabbitmq.md](02-rabbitmq.md) | RabbitMQ - message queue giữa các service |
| [03-memcached.md](03-memcached.md) | Memcached - cache token validation |

### Identity Service (02-keystone)
| File | Nội dung |
|---|---|
| [04-keystone-deep-dive.md](04-keystone-deep-dive.md) | Keystone - authentication, authorization, Fernet token, service catalog |

### Image Service (03-glance)
| File | Nội dung |
|---|---|
| [05-glance-deep-dive.md](05-glance-deep-dive.md) | Glance - image format, backend, quota, upload flow |

### Placement API (04-placement)
| File | Nội dung |
|---|---|
| [06-placement-deep-dive.md](06-placement-deep-dive.md) | Placement - resource provider, inventory, allocation, trait, nested providers |

### Compute Service (05-nova)
| File | Nội dung |
|---|---|
| [07-nova-deep-dive.md](07-nova-deep-dive.md) | Nova - components, cell v2, scheduler filters, instance lifecycle |

### Networking Service (06-neutron)
| File | Nội dung |
|---|---|
| [08-neutron-ovn-deep-dive.md](08-neutron-ovn-deep-dive.md) | Neutron + OVN - ML2, NB/SB DB, ovn-controller, gateway chassis, security groups |

### Dashboard (08-horizon)
| File | Nội dung |
|---|---|
| [09-horizon-deep-dive.md](09-horizon-deep-dive.md) | Horizon - Django, offline compression, Project vs Admin panel |

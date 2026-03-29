# RabbitMQ trong OpenStack

## RabbitMQ là gì?

RabbitMQ là message broker - hệ thống trung gian truyền message giữa các service. Trong OpenStack, RabbitMQ là **"bưu điện"** - các service không gọi nhau trực tiếp mà gửi message qua RabbitMQ.

## Tại sao cần Message Queue?

```
Không có MQ (direct call):
Nova API → gọi trực tiếp → Nova Compute
  - Nếu Compute bận → API bị block
  - Nếu Compute chết → request mất
  - Khó scale

Có MQ (async):
Nova API → đẩy message → RabbitMQ Queue → Nova Compute lấy ra xử lý
  - API không bị block
  - Message được lưu lại nếu Compute tạm thời chết
  - Dễ scale: thêm nhiều Compute worker cùng consume 1 queue
```

## Kiến trúc AMQP trong OpenStack

```
Producer (Nova API)
    │
    │ publish message
    ▼
Exchange (topic exchange)
    │
    │ routing key: compute
    ▼
Queue: compute.controller / compute.compute1
    │
    │ consume message
    ▼
Consumer (Nova Conductor / Nova Compute)
```

**Exchange types OpenStack dùng:**
- `topic`: route theo routing key pattern (dùng nhiều nhất)
- `fanout`: broadcast đến tất cả queue (dùng cho cast)
- `direct`: route chính xác theo key

## Các loại message trong Nova

```
RPC Call (có reply):
  Nova API → [request queue] → Nova Conductor
  Nova API ← [reply queue]   ← Nova Conductor

RPC Cast (không reply):
  Nova API → [compute queue] → Nova Compute
  (fire and forget)
```

## Cấu hình trong OpenStack

```ini
# nova.conf, neutron.conf, cinder.conf...
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller:5672/
```

Format: `rabbit://user:password@host:port/vhost`

- Port mặc định: `5672`
- Vhost mặc định: `/` (root vhost)

## Quản lý RabbitMQ

```bash
# Xem tất cả queue
rabbitmqctl list_queues name messages consumers

# Xem connection
rabbitmqctl list_connections

# Xem exchange
rabbitmqctl list_exchanges

# Xem user
rabbitmqctl list_users

# Xem permission
rabbitmqctl list_permissions

# Enable management UI (port 15672)
rabbitmq-plugins enable rabbitmq_management
```

## Debug

```bash
# Queue của Nova có message tồn đọng không?
rabbitmqctl list_queues | grep nova

# Kết quả bình thường: messages = 0
# Nếu messages tăng cao → consumer bị chết hoặc quá tải

# Xem log
tail -f /var/log/rabbitmq/rabbit@controller.log
```

## High Availability

Trong production, RabbitMQ thường chạy cluster 3 node với mirrored queues để tránh mất message khi 1 node chết. Trong lab này chỉ dùng 1 node.

```
Production:
rabbit1 ←→ rabbit2 ←→ rabbit3
(mirrored queues - mỗi message được replicate sang tất cả node)
```

# Инструкция по offline-установке AWX 24.6.1 с кастомизацией

## Обзор

Данная инструкция описывает установку AWX 24.6.1 на сервер без доступа в интернет с возможностью настройки:

- **Сетевых параметров** (Pod CIDR, Service CIDR, NodePort)
- **Путей хранения данных** (база данных, проекты)
- **Ресурсов контейнеров** (CPU, память)

---

## Структура файлов

```
.
├── README.md                              # Эта инструкция
└── awx_offline_install_script/
    ├── create-awx-offline.sh              # Создание дистрибутива
    ├── install-awx-offline.sh             # Установка AWX
    ├── awx-config.env                     # Конфигурация
    ├── check-awx.sh                       # Проверка статуса AWX
    ├── check-k3s-network.sh               # Проверка сети
    └── check-storage.sh                   # Проверка хранилища
```

---

## Часть 1: Требования

### Машина для подготовки дистрибутива (с интернетом)

| Параметр | Требование |
|----------|------------|
| ОС | Linux (AstraLinux, RedOS) |
| Docker | Установлен и запущен |
| Диск | 5 ГБ свободного места |
| Интернет | Доступ к quay.io, github.com, docker.io |

### Целевой сервер (без интернета)

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| ОС | AstraLinux / RedOS | RedOS |
| CPU | 4 ядра | 8 ядер |
| RAM | 8 ГБ | 16 ГБ |
| Диск | 40 ГБ | 80 ГБ |
| Доступ | root или sudo | — |

### Важные ограничения
- **AstraLInux** личное мнение, не рекомендую к использованию, слишком много лишнего ПО, система не предсказуема. Нет бесплатной версии.
- **K3s и containerd** всегда устанавливаются в `/var/lib/rancher/k3s` — этот путь изменять нельзя
- **Сетевые диапазоны** Pod CIDR и Service CIDR не должны пересекаться с вашей корпоративной сетью
- **PostgreSQL** требует права 700 и владельца UID 26 на директорию данных

---

## Часть 2: Подготовка дистрибутива

### Шаг 2.1: Подготовка машины с интернетом

#### Astra Linux:

```bash
sudo apt update
sudo apt install -y docker.io curl jq
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER
```

#### RedOS:

```bash
sudo dnf install -y docker curl jq
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER
```

### Шаг 2.2: Запуск скрипта создания дистрибутива

```bash
cd awx_offline_install_script
chmod +x *.sh
./create-awx-offline.sh
```

Скрипт выполнит:
- Скачивание K3s и его air-gap образов
- Скачивание Kustomize
- Скачивание всех Docker-образов AWX
- Создание манифеста AWX Operator с исправленными тегами образов
- Копирование скриптов установки и проверки

### Шаг 2.3: Результат

После выполнения в домашней директории появится:

```
~/awx-offline/
├── awx-config.env                    # Конфигурация (редактировать!)
├── install-awx-offline.sh            # Скрипт установки
├── awx-operator-full.yaml            # Манифест оператора
├── k3s                               # Бинарник K3s (~60 МБ)
├── install-k3s.sh                    # Установщик K3s
├── check-awx.sh                      # Проверка AWX
├── check-k3s-network.sh              # Проверка сети
├── check-storage.sh                  # Проверка хранилища
└── Images/
    ├── k3s-airgap-images-amd64.tar.zst   # (~200 МБ)
    ├── kustomize.tar.gz                   # (~15 МБ)
    ├── awx-operator.tar                   # (~200 МБ)
    ├── awx.tar                            # (~350 МБ)
    ├── awx-ee.tar                         # (~500 МБ)
    ├── kube-rbac-proxy.tar                # (~70 МБ)
    ├── postgresql.tar                     # (~200 МБ)
    ├── centos.tar                         # (~60 МБ)
    └── redis.tar                          # (~45 МБ)
```

### Шаг 2.4: Создание архива для переноса

```bash
cd ~
tar czvf awx-offline-bundle.tar.gz awx-offline/
```

Размер архива: **~2–2.5 ГБ**

---

## Часть 3: Перенос на целевой сервер

### Вариант A: USB-накопитель

```bash
# На машине с интернетом
cp ~/awx-offline-bundle.tar.gz /media/usb/

# На целевом сервере
cp /media/usb/awx-offline-bundle.tar.gz /tmp/
```

### Вариант B: SCP через промежуточный сервер

```bash
# С машины с интернетом на промежуточный сервер
scp ~/awx-offline-bundle.tar.gz user@jumphost:/tmp/

# С промежуточного сервера на целевой
scp /tmp/awx-offline-bundle.tar.gz user@target:/tmp/
```

---

## Часть 4: Установка на целевом сервере

### Шаг 4.1: Распаковка архива

```bash
cd /tmp
tar xzvf awx-offline-bundle.tar.gz
cd awx-offline
```

### Шаг 4.2: Редактирование конфигурации

```bash
nano awx-config.env
```

Основные параметры для редактирования:

```bash
# Сеть (убедитесь, что не пересекается с вашей сетью!)
POD_CIDR="192.168.168.0/24"
SERVICE_CIDR="192.168.169.0/24"
AWX_NODE_PORT="30080"

# Хранилище
CUSTOM_STORAGE_ENABLED="true"
AWX_DATA_DIR="/var/awx/data"
POSTGRES_STORAGE_SIZE="10Gi"
PROJECTS_STORAGE_SIZE="8Gi"
```

### Шаг 4.3: Запуск установки

```bash
sudo ./install-awx-offline.sh
```

Скрипт покажет конфигурацию и запросит подтверждение:

```
========================================================================
                    КОНФИГУРАЦИЯ УСТАНОВКИ
========================================================================

Сетевые настройки:
  Pod CIDR:        192.168.168.0/24
  Service CIDR:    192.168.169.0/24
  AWX NodePort:    30080

Хранилище:
  Custom Storage:  true
  AWX Data Dir:    /var/awx/data
  PostgreSQL:      /var/awx/data/postgres
  Projects:        /var/awx/data/projects

========================================================================

Продолжить установку с этими параметрами? (y/n):
```

### Шаг 4.4: Процесс установки

Установка выполняется в 7 этапов:

1. **[1/7] Установка K3s** — копирование бинарников, настройка сети
2. **[2/7] Настройка kubeconfig** — конфигурация kubectl
3. **[3/7] Ожидание готовности K3s** — проверка состояния кластера
4. **[4/7] Импорт Docker-образов** — загрузка образов в containerd
5. **[5/7] Установка Kustomize** — утилита для работы с манифестами
6. **[6/7] Настройка хранилища** — создание StorageClass и PV (если включено)
7. **[7/7] Установка AWX** — деплой оператора и AWX

Общее время: **10–20 минут**

### Шаг 4.5: Результат установки

```
========================================================================
          AWX 24.6.1 УСТАНОВЛЕН УСПЕШНО
========================================================================

Сеть:
  Pod CIDR:     192.168.168.0/24
  Service CIDR: 192.168.169.0/24

Хранилище:
  PostgreSQL: /var/awx/data/postgres
  Projects:   /var/awx/data/projects

Статус подов:
NAME                                              READY   STATUS
awx-operator-controller-manager-xxxxx             2/2     Running
awx-postgres-15-0                                 1/1     Running
awx-web-xxxxx                                     3/3     Running
awx-task-xxxxx                                    4/4     Running

------------------------------------------------------------------------

URL:      http://192.168.1.100:30080
Логин:    admin
Пароль:   xxxxxxxxxxxxxxxx

------------------------------------------------------------------------
```

---

## Часть 5: Конфигурация

### Полный список параметров (awx-config.env)

#### Сетевые настройки

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `POD_CIDR` | Сеть для подов Kubernetes | `192.168.168.0/24` |
| `SERVICE_CIDR` | Сеть для сервисов Kubernetes | `192.168.169.0/24` |
| `AWX_NODE_PORT` | Порт веб-интерфейса AWX | `30080` |

#### Хранилище

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `CUSTOM_STORAGE_ENABLED` | Использовать кастомные пути | `true` |
| `AWX_DATA_DIR` | Базовая директория данных | `/var/awx/data` |
| `POSTGRES_DATA_DIR` | Путь для PostgreSQL | `${AWX_DATA_DIR}/postgres` |
| `PROJECTS_DATA_DIR` | Путь для проектов AWX | `${AWX_DATA_DIR}/projects` |
| `POSTGRES_STORAGE_SIZE` | Размер тома БД | `10Gi` |
| `PROJECTS_STORAGE_SIZE` | Размер тома проектов | `8Gi` |

#### Ресурсы контейнеров

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `AWX_WEB_CPU_REQUEST` | CPU request для web | `100m` |
| `AWX_WEB_CPU_LIMIT` | CPU limit для web | `2000m` |
| `AWX_WEB_MEMORY_REQUEST` | Memory request для web | `256Mi` |
| `AWX_WEB_MEMORY_LIMIT` | Memory limit для web | `4Gi` |
| `AWX_TASK_CPU_REQUEST` | CPU request для task | `100m` |
| `AWX_TASK_CPU_LIMIT` | CPU limit для task | `2000m` |
| `AWX_TASK_MEMORY_REQUEST` | Memory request для task | `256Mi` |
| `AWX_TASK_MEMORY_LIMIT` | Memory limit для task | `4Gi` |
| `AWX_EE_CPU_REQUEST` | CPU request для EE | `100m` |
| `AWX_EE_CPU_LIMIT` | CPU limit для EE | `1000m` |
| `AWX_EE_MEMORY_REQUEST` | Memory request для EE | `128Mi` |
| `AWX_EE_MEMORY_LIMIT` | Memory limit для EE | `2Gi` |

#### Дополнительные

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `AWX_INSTANCE_NAME` | Имя инстанса AWX | `awx` |
| `AWX_NAMESPACE` | Namespace Kubernetes | `awx` |

### Примеры конфигураций

#### Минимальная (по умолчанию)

```bash
POD_CIDR="192.168.168.0/24"
SERVICE_CIDR="192.168.169.0/24"
AWX_NODE_PORT="30080"
CUSTOM_STORAGE_ENABLED="false"
```

#### Кастомное хранилище на отдельном диске

```bash
POD_CIDR="192.168.168.0/24"
SERVICE_CIDR="192.168.169.0/24"
AWX_NODE_PORT="30080"

CUSTOM_STORAGE_ENABLED="true"
AWX_DATA_DIR="/mnt/data/awx"
POSTGRES_STORAGE_SIZE="50Gi"
PROJECTS_STORAGE_SIZE="20Gi"
```

#### Продакшн с увеличенными ресурсами

```bash
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.245.0.0/16"
AWX_NODE_PORT="30443"

CUSTOM_STORAGE_ENABLED="true"
AWX_DATA_DIR="/opt/awx-data"
POSTGRES_STORAGE_SIZE="100Gi"
PROJECTS_STORAGE_SIZE="50Gi"

AWX_WEB_CPU_LIMIT="4000m"
AWX_WEB_MEMORY_LIMIT="8Gi"
AWX_TASK_CPU_LIMIT="4000m"
AWX_TASK_MEMORY_LIMIT="8Gi"
AWX_EE_CPU_LIMIT="2000m"
AWX_EE_MEMORY_LIMIT="4Gi"
```

---

## Часть 6: Проверка установки

### Скрипты проверки

После установки в домашней директории пользователя доступны скрипты:

```bash
~/check-awx.sh          # Статус AWX
~/check-k3s-network.sh  # Сетевая конфигурация
~/check-storage.sh      # Хранилище
```

### Проверка статуса AWX

```bash
~/check-awx.sh
```

Вывод:

```
=== Проверка AWX ===

[1] Статус K3s:
  Active: active (running)

[2] Статус подов AWX:
NAME                                              READY   STATUS
awx-operator-controller-manager-xxxxx             2/2     Running
awx-postgres-15-0                                 1/1     Running
awx-web-xxxxx                                     3/3     Running
awx-task-xxxxx                                    4/4     Running

[3] Сервисы:
NAME          TYPE       CLUSTER-IP       PORT(S)
awx-service   NodePort   192.168.169.x    80:30080/TCP

[4] PVC:
NAME                            STATUS   CAPACITY
postgres-15-awx-postgres-15-0   Bound    10Gi
awx-projects-claim              Bound    8Gi

[5] Веб-интерфейс:
  ✓ Доступен: http://192.168.1.100:30080

[6] Пароль admin:
  xxxxxxxxxxxxxxxx
```

### Проверка сети

```bash
~/check-k3s-network.sh
```

Вывод:

```
=== K3s Network ===

[1] Node IP:
  192.168.1.100

[2] Pod CIDR:
  192.168.168.0/24

[3] Service CIDR:
  192.168.169.0/24

[4] Pod IPs:
  awx-web-xxxxx: 192.168.168.5
  awx-task-xxxxx: 192.168.168.6
  awx-postgres-15-0: 192.168.168.4

[5] Service IPs:
  awx-service: 192.168.169.10
  awx-postgres-15: 192.168.169.11
```

### Проверка хранилища

```bash
~/check-storage.sh
```

Вывод:

```
=== AWX Storage ===

[1] Persistent Volumes:
NAME              CAPACITY   STATUS   STORAGECLASS
awx-postgres-pv   10Gi       Bound    awx-local-storage
awx-projects-pv   8Gi        Bound    awx-local-storage

[2] Persistent Volume Claims:
NAME                            STATUS   CAPACITY
postgres-15-awx-postgres-15-0   Bound    10Gi
awx-projects-claim              Bound    8Gi

[3] Размер данных:
  /var/awx/data/postgres: 156M
  /var/awx/data/projects: 4.0K

[4] Права на директории:
  /var/awx/data/postgres: 700 26:26
  /var/awx/data/projects: 755 root:root
```

---

## Часть 7: Структура хранилища

### При CUSTOM_STORAGE_ENABLED="false"

```
/var/lib/rancher/k3s/
├── agent/
│   ├── containerd/              # Образы контейнеров
│   └── images/                  # Air-gap образы
├── server/
│   └── db/                      # Состояние кластера
└── storage/
    ├── pvc-xxx_postgres-15/     # База данных PostgreSQL
    │   └── userdata/data/
    └── pvc-xxx_projects/        # Проекты AWX
        └── _1/, _2/, ...
```

### При CUSTOM_STORAGE_ENABLED="true"

```
/var/awx/data/                   # AWX_DATA_DIR
├── postgres/                    # База данных PostgreSQL
│   └── userdata/data/          # Владелец: 26:26, права: 700
└── projects/                    # Проекты AWX
    └── _1/, _2/, ...

/var/lib/rancher/k3s/            # K3s (НЕ ИЗМЕНЯТЬ!)
├── agent/
│   ├── containerd/
│   └── images/
└── server/
    └── db/
```

---

## Часть 8: Автозапуск после перезагрузки

AWX автоматически запускается после перезагрузки сервера:

1. **K3s** настроен как systemd-служба с автозапуском
2. **Kubernetes** автоматически восстанавливает все поды
3. **Данные** сохраняются в персистентных томах

### Проверка после перезагрузки

```bash
# Подождите 3-5 минут после загрузки системы
~/check-awx.sh
```

### Время запуска компонентов

| Компонент | Время после перезагрузки |
|-----------|-------------------------|
| K3s | 30–60 секунд |
| PostgreSQL | +30 секунд |
| AWX Operator | +30 секунд |
| AWX Web/Task | +60–120 секунд |
| **Полная готовность** | **3–5 минут** |

---

## Часть 9: Устранение неполадок

### Проблема: PostgreSQL в CrashLoopBackOff

**Симптомы:**

```
awx-postgres-15-0   0/1   CrashLoopBackOff   5   10m
```

**Причина:** Неправильные права на директорию данных.

**Решение:**

```bash
# Проверка логов
kubectl -n awx logs awx-postgres-15-0

# Исправление прав
sudo chown -R 26:26 /var/awx/data/postgres
sudo chmod 700 /var/awx/data/postgres

# Перезапуск пода
kubectl -n awx delete pod awx-postgres-15-0
```

### Проблема: K3s не запускается (containerd.sock not found)

**Симптомы:**

```
connection error: dial unix /run/k3s/containerd/containerd.sock: connect: no such file
```

**Причина:** Повреждение установки K3s или неправильная конфигурация.

**Решение:**

```bash
# Полная очистка
sudo /usr/local/bin/k3s-uninstall.sh
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /etc/rancher/k3s

# Переустановка
sudo ./install-awx-offline.sh
```

### Проблема: Таймаут ожидания K3s

**Симптомы:**

```
[ERROR] Таймаут ожидания K3s
```

**Решение:**

```bash
# Проверка статуса службы
sudo systemctl status k3s
sudo journalctl -u k3s -n 50

# Ручная проверка
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes
```

### Проблема: ImagePullBackOff

**Симптомы:**

```
awx-operator-controller-manager-xxxxx   1/2   ImagePullBackOff
```

**Причина:** Образ не импортирован в containerd.

**Решение:**

```bash
# Проверка образов
sudo k3s ctr images list | grep awx

# Ручной импорт
cd /tmp/awx-offline/Images
sudo k3s ctr images import awx-operator.tar
sudo k3s ctr images import awx.tar
# ... и т.д.

# Создание тега для kube-rbac-proxy
sudo k3s ctr images tag \
    quay.io/brancz/kube-rbac-proxy:v0.18.0 \
    gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0
```

### Проблема: PVC в Pending

**Симптомы:**

```
awx-projects-claim   Pending
```

**Решение:**

```bash
# Диагностика
kubectl -n awx describe pvc awx-projects-claim
kubectl get pv

# Проверка директорий
ls -la /var/awx/data/

# Проверка StorageClass
kubectl get storageclass
```

### Проблема: Сетевой конфликт

**Симптомы:** Поды не могут связаться друг с другом или с внешней сетью.

**Решение:**

```bash
# Проверка маршрутов
ip route

# Если есть конфликт, измените CIDR в awx-config.env
# и переустановите K3s
sudo /usr/local/bin/k3s-uninstall.sh
sudo ./install-awx-offline.sh
```

---

## Часть 10: Полезные команды

### Управление AWX

```bash
# Статус подов
kubectl -n awx get pods

# Логи PostgreSQL
kubectl -n awx logs awx-postgres-15-0

# Логи AWX Web
kubectl -n awx logs -l app.kubernetes.io/name=awx-web -c awx-web

# Логи AWX Task
kubectl -n awx logs -l app.kubernetes.io/name=awx-task -c awx-task

# Перезапуск компонентов
kubectl -n awx rollout restart deployment/awx-web
kubectl -n awx rollout restart deployment/awx-task

# Сброс пароля admin
kubectl -n awx exec -it deployment/awx-web -c awx-web -- awx-manage changepassword admin
```

### Резервное копирование

```bash
# Через AWX Operator
cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWXBackup
metadata:
  name: backup-$(date +%Y%m%d-%H%M)
  namespace: awx
spec:
  deployment_name: awx
EOF

# Проверка статуса бэкапа
kubectl -n awx get awxbackup

# Ручной бэкап
sudo tar czvf awx-postgres-backup-$(date +%Y%m%d).tar.gz /var/awx/data/postgres/
sudo tar czvf awx-projects-backup-$(date +%Y%m%d).tar.gz /var/awx/data/projects/
```

### Восстановление

```bash
# Через AWX Operator
cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWXRestore
metadata:
  name: restore-$(date +%Y%m%d)
  namespace: awx
spec:
  deployment_name: awx
  backup_name: backup-20240101-1200
EOF
```

### Полное удаление

```bash
# Удаление AWX
kubectl delete -f /tmp/awx-offline/awx-instance.yaml
kubectl delete -f /tmp/awx-offline/awx-operator-full.yaml
kubectl delete namespace awx
kubectl delete pv awx-postgres-pv awx-projects-pv

# Удаление K3s
sudo /usr/local/bin/k3s-uninstall.sh

# Удаление данных
sudo rm -rf /var/awx/data
sudo rm -rf /var/lib/rancher/k3s
```

---

## Часть 11: Версии компонентов

| Компонент | Версия |
|-----------|--------|
| AWX | 24.6.1 |
| AWX Operator | 2.19.1 |
| K3s | v1.31.2+k3s1 |
| Kubernetes | 1.31.2 |
| Kustomize | 5.4.3 |
| PostgreSQL | 15 |
| Redis | 7 |
| kube-rbac-proxy | v0.18.0 |

---

## Контрольный список установки

### На машине с интернетом:

- [ ] Установлен Docker
- [ ] Клонирован/скопирован каталог `awx_offline_install_script`
- [ ] Выполнен `./create-awx-offline.sh`
- [ ] Создан архив `tar czvf awx-offline-bundle.tar.gz awx-offline/`
- [ ] Архив перенесён на целевой сервер

### На целевом сервере:

- [ ] Распакован архив `tar xzvf awx-offline-bundle.tar.gz`
- [ ] Отредактирован `awx-config.env`
- [ ] Выполнен `sudo ./install-awx-offline.sh`
- [ ] Подтверждена конфигурация (y)
- [ ] Все поды в статусе Running
- [ ] Веб-интерфейс доступен
- [ ] Успешный вход под `admin`
- [ ] Скрипты проверки работают

---

## Поддержка

При возникновении проблем:

1. Проверьте логи: `kubectl -n awx logs <pod-name>`
2. Проверьте события: `kubectl -n awx get events --sort-by='.lastTimestamp'`
3. Используйте скрипты проверки: `~/check-awx.sh`, `~/check-k3s-network.sh`, `~/check-storage.sh`

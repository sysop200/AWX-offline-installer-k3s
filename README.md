# Инструкция по offline-установке AWX 24.6.1 с полной кастомизацией

## Обзор

Данная инструкция описывает установку AWX 24.6.1 на сервер без доступа в интернет с возможностью настройки:

- **Сетевых параметров** (Pod CIDR, Service CIDR, NodePort)
- **Путей хранения данных** (база данных, проекты)
- **Ресурсов контейнеров** (CPU, память)

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
| ОС | AstraLinux, RedOS | RedOS |
| CPU | 4 ядра | 8 ядер |
| RAM | 8 ГБ | 16 ГБ |
| Диск | 40 ГБ | 80 ГБ |
| Доступ | root или sudo | — |

> **RedOS**, на мой взгляд более адапрированная система. АстраЛинукс ставит кучу разных пакетов не требующихся в работе AWX.

### Важные ограничения

> **⚠️ K3s и containerd** всегда должны оставаться в стандартных путях (`/var/lib/rancher/k3s`). Кастомизация путей применяется **только** к данным приложений (PostgreSQL, проекты AWX).

> **⚠️ Сетевые диапазоны** Pod CIDR и Service CIDR не должны пересекаться с вашей корпоративной сетью.

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

### Шаг 2.2: Создание скрипта подготовки дистрибутива

```bash
cat <<'SCRIPT' > ~/create-awx-offline.sh
#!/bin/bash
set -e

#===============================================================================
# Скрипт создания offline-дистрибутива AWX 24.6.1
# С поддержкой кастомизации сети и хранилища
#===============================================================================

# Версии компонентов
K3S_VERSION="v1.31.2+k3s1"
KUSTOMIZE_VERSION="5.4.3"
AWX_OPERATOR_VERSION="2.19.1"
AWX_VERSION="24.6.1"
KUBE_RBAC_PROXY_VERSION="v0.18.0"

# Директория для дистрибутива
DIST_DIR="$HOME/awx-offline"
IMAGES_DIR="$DIST_DIR/Images"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#-------------------------------------------------------------------------------
check_dependencies() {
    log_info "Проверка зависимостей..."

    local missing=()
    command -v docker &>/dev/null || missing+=("docker")
    command -v curl &>/dev/null || missing+=("curl")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Отсутствуют: ${missing[*]}"
        echo "Установите: sudo apt install -y docker.io curl"
        exit 1
    fi

    docker info &>/dev/null || {
        log_error "Docker не запущен"
        exit 1
    }

    log_info "Зависимости OK"
}

#-------------------------------------------------------------------------------
create_directories() {
    log_info "Создание директорий..."
    rm -rf "$DIST_DIR"
    mkdir -p "$IMAGES_DIR"
}

#-------------------------------------------------------------------------------
download_k3s() {
    log_info "Скачивание K3s ${K3S_VERSION}..."

    curl -Lo "$DIST_DIR/k3s" \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s"
    chmod +x "$DIST_DIR/k3s"

    curl -Lo "$DIST_DIR/install-k3s.sh" "https://get.k3s.io"
    chmod +x "$DIST_DIR/install-k3s.sh"

    curl -Lo "$IMAGES_DIR/k3s-airgap-images-amd64.tar.zst" \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"
}

#-------------------------------------------------------------------------------
download_kustomize() {
    log_info "Скачивание Kustomize ${KUSTOMIZE_VERSION}..."

    curl -Lo "$IMAGES_DIR/kustomize.tar.gz" \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
}

#-------------------------------------------------------------------------------
download_images() {
    log_info "Скачивание Docker-образов..."

    declare -A IMAGES=(
        ["awx-operator"]="quay.io/ansible/awx-operator:${AWX_OPERATOR_VERSION}"
        ["awx"]="quay.io/ansible/awx:${AWX_VERSION}"
        ["awx-ee"]="quay.io/ansible/awx-ee:${AWX_VERSION}"
        ["kube-rbac-proxy"]="quay.io/brancz/kube-rbac-proxy:${KUBE_RBAC_PROXY_VERSION}"
        ["postgresql"]="quay.io/sclorg/postgresql-15-c9s:latest"
        ["centos"]="quay.io/centos/centos:stream9"
        ["redis"]="docker.io/redis:7"
    )

    for name in "${!IMAGES[@]}"; do
        log_info "  $name..."
        docker pull "${IMAGES[$name]}"
        docker save "${IMAGES[$name]}" -o "$IMAGES_DIR/${name}.tar"
    done
}

#-------------------------------------------------------------------------------
create_operator_manifest() {
    log_info "Создание манифеста AWX Operator..."

    tar xzf "$IMAGES_DIR/kustomize.tar.gz" -C /tmp

    /tmp/kustomize build \
        "github.com/ansible/awx-operator/config/default?ref=${AWX_OPERATOR_VERSION}" \
        > "$DIST_DIR/awx-operator-full.yaml"

    # Замена недоступного образа kube-rbac-proxy
    sed -i "s|gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0|quay.io/brancz/kube-rbac-proxy:${KUBE_RBAC_PROXY_VERSION}|g" \
        "$DIST_DIR/awx-operator-full.yaml"

    # Замена latest на конкретную версию
    sed -i "s|quay.io/ansible/awx-operator:latest|quay.io/ansible/awx-operator:${AWX_OPERATOR_VERSION}|g" \
        "$DIST_DIR/awx-operator-full.yaml"

    rm -f /tmp/kustomize
}

#-------------------------------------------------------------------------------
create_config_file() {
    log_info "Создание конфигурационного файла..."

    cat <<'EOF' > "$DIST_DIR/awx-config.env"
#===============================================================================
# AWX 24.6.1 - Конфигурационный файл
# Отредактируйте параметры перед запуском установки
#===============================================================================

#-------------------------------------------------------------------------------
# СЕТЕВЫЕ НАСТРОЙКИ
#-------------------------------------------------------------------------------

# Сеть для подов (Pod Network)
# Убедитесь, что этот диапазон НЕ используется в вашей сети!
POD_CIDR="192.168.168.0/24"

# Сеть для сервисов Kubernetes (Service Network)
# Убедитесь, что этот диапазон НЕ используется в вашей сети!
SERVICE_CIDR="192.168.169.0/24"

# Порт для доступа к веб-интерфейсу AWX (NodePort)
# Диапазон допустимых значений: 30000-32767
AWX_NODE_PORT="30080"

#-------------------------------------------------------------------------------
# НАСТРОЙКИ ХРАНИЛИЩА
#-------------------------------------------------------------------------------

# Включить кастомные пути хранения (true/false)
# Если false - используются пути по умолчанию K3s (/var/lib/rancher/k3s/storage)
CUSTOM_STORAGE_ENABLED="true"

# Базовая директория для данных AWX
AWX_DATA_DIR="/var/awx/data"

# Путь для данных PostgreSQL (база данных AWX)
# PostgreSQL требует права 700 и владельца UID 26
POSTGRES_DATA_DIR="${AWX_DATA_DIR}/postgres"

# Путь для проектов AWX (playbooks, roles и т.д.)
PROJECTS_DATA_DIR="${AWX_DATA_DIR}/projects"

#-------------------------------------------------------------------------------
# РАЗМЕРЫ ТОМОВ
#-------------------------------------------------------------------------------

# Размер тома для PostgreSQL
POSTGRES_STORAGE_SIZE="10Gi"

# Размер тома для проектов
PROJECTS_STORAGE_SIZE="8Gi"

#-------------------------------------------------------------------------------
# РЕСУРСЫ КОНТЕЙНЕРОВ
#-------------------------------------------------------------------------------

# AWX Web (requests / limits)
AWX_WEB_CPU_REQUEST="100m"
AWX_WEB_CPU_LIMIT="2000m"
AWX_WEB_MEMORY_REQUEST="256Mi"
AWX_WEB_MEMORY_LIMIT="4Gi"

# AWX Task
AWX_TASK_CPU_REQUEST="100m"
AWX_TASK_CPU_LIMIT="2000m"
AWX_TASK_MEMORY_REQUEST="256Mi"
AWX_TASK_MEMORY_LIMIT="4Gi"

# AWX Execution Environment
AWX_EE_CPU_REQUEST="100m"
AWX_EE_CPU_LIMIT="1000m"
AWX_EE_MEMORY_REQUEST="128Mi"
AWX_EE_MEMORY_LIMIT="2Gi"

#-------------------------------------------------------------------------------
# ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ
#-------------------------------------------------------------------------------

# Имя инстанса AWX
AWX_INSTANCE_NAME="awx"

# Namespace для AWX
AWX_NAMESPACE="awx"
EOF

    log_info "Конфигурационный файл создан"
}

#-------------------------------------------------------------------------------
create_install_script() {
    log_info "Создание установочного скрипта..."

    cat <<'INSTALL_SCRIPT' > "$DIST_DIR/install-awx-offline.sh"
#!/bin/bash
set -e

#===============================================================================
# Скрипт установки AWX 24.6.1 (offline) с кастомизацией
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="$SCRIPT_DIR/Images"
CONFIG_FILE="$SCRIPT_DIR/awx-config.env"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

#-------------------------------------------------------------------------------
# Загрузка конфигурации
#-------------------------------------------------------------------------------
load_config() {
    log_info "Загрузка конфигурации..."

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Конфигурационный файл не найден: $CONFIG_FILE"
        exit 1
    fi

    source "$CONFIG_FILE"

    # Установка значений по умолчанию
    POD_CIDR="${POD_CIDR:-192.168.168.0/24}"
    SERVICE_CIDR="${SERVICE_CIDR:-192.168.169.0/24}"
    AWX_NODE_PORT="${AWX_NODE_PORT:-30080}"
    CUSTOM_STORAGE_ENABLED="${CUSTOM_STORAGE_ENABLED:-false}"
    AWX_DATA_DIR="${AWX_DATA_DIR:-/var/awx/data}"
    POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-${AWX_DATA_DIR}/postgres}"
    PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-${AWX_DATA_DIR}/projects}"
    K3S_DATA_DIR="/var/lib/rancher/k3s"
    POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-10Gi}"
    PROJECTS_STORAGE_SIZE="${PROJECTS_STORAGE_SIZE:-8Gi}"
    AWX_WEB_CPU_REQUEST="${AWX_WEB_CPU_REQUEST:-100m}"
    AWX_WEB_CPU_LIMIT="${AWX_WEB_CPU_LIMIT:-2000m}"
    AWX_WEB_MEMORY_REQUEST="${AWX_WEB_MEMORY_REQUEST:-256Mi}"
    AWX_WEB_MEMORY_LIMIT="${AWX_WEB_MEMORY_LIMIT:-4Gi}"
    AWX_TASK_CPU_REQUEST="${AWX_TASK_CPU_REQUEST:-100m}"
    AWX_TASK_CPU_LIMIT="${AWX_TASK_CPU_LIMIT:-2000m}"
    AWX_TASK_MEMORY_REQUEST="${AWX_TASK_MEMORY_REQUEST:-256Mi}"
    AWX_TASK_MEMORY_LIMIT="${AWX_TASK_MEMORY_LIMIT:-4Gi}"
    AWX_EE_CPU_REQUEST="${AWX_EE_CPU_REQUEST:-100m}"
    AWX_EE_CPU_LIMIT="${AWX_EE_CPU_LIMIT:-1000m}"
    AWX_EE_MEMORY_REQUEST="${AWX_EE_MEMORY_REQUEST:-128Mi}"
    AWX_EE_MEMORY_LIMIT="${AWX_EE_MEMORY_LIMIT:-2Gi}"
    AWX_INSTANCE_NAME="${AWX_INSTANCE_NAME:-awx}"
    AWX_NAMESPACE="${AWX_NAMESPACE:-awx}"

    log_info "Конфигурация загружена"
}

#-------------------------------------------------------------------------------
# Вывод конфигурации
#-------------------------------------------------------------------------------
print_config() {
    echo ""
    echo "========================================================================"
    echo "                    КОНФИГУРАЦИЯ УСТАНОВКИ"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}Сетевые настройки:${NC}"
    echo "  Pod CIDR:        $POD_CIDR"
    echo "  Service CIDR:    $SERVICE_CIDR"
    echo "  AWX NodePort:    $AWX_NODE_PORT"
    echo ""
    echo -e "${CYAN}Хранилище:${NC}"
    echo "  Custom Storage:  $CUSTOM_STORAGE_ENABLED"
    if [ "$CUSTOM_STORAGE_ENABLED" = "true" ]; then
        echo "  AWX Data Dir:    $AWX_DATA_DIR"
        echo "  PostgreSQL:      $POSTGRES_DATA_DIR"
        echo "  Projects:        $PROJECTS_DATA_DIR"
    else
        echo "  Используется:    /var/lib/rancher/k3s/storage/"
    fi
    echo "  PostgreSQL Size: $POSTGRES_STORAGE_SIZE"
    echo "  Projects Size:   $PROJECTS_STORAGE_SIZE"
    echo ""
    echo -e "${CYAN}Ресурсы:${NC}"
    echo "  Web CPU:         $AWX_WEB_CPU_REQUEST / $AWX_WEB_CPU_LIMIT"
    echo "  Web Memory:      $AWX_WEB_MEMORY_REQUEST / $AWX_WEB_MEMORY_LIMIT"
    echo "  Task CPU:        $AWX_TASK_CPU_REQUEST / $AWX_TASK_CPU_LIMIT"
    echo "  Task Memory:     $AWX_TASK_MEMORY_REQUEST / $AWX_TASK_MEMORY_LIMIT"
    echo ""
    echo "========================================================================"
    echo ""
}

#-------------------------------------------------------------------------------
# Проверка root
#-------------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Скрипт должен запускаться с правами root"
        echo "Используйте: sudo $0"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Проверка сетевых конфликтов
#-------------------------------------------------------------------------------
check_network_conflicts() {
    log_info "Проверка сетевых конфликтов..."

    local pod_net=$(echo "$POD_CIDR" | cut -d'/' -f1 | cut -d'.' -f1-3)
    local svc_net=$(echo "$SERVICE_CIDR" | cut -d'/' -f1 | cut -d'.' -f1-3)

    if ip route | grep -q "$pod_net"; then
        log_warn "Сеть $POD_CIDR может конфликтовать с существующими маршрутами!"
        ip route | grep "$pod_net"
        read -p "Продолжить? (y/n): " response
        [ "$response" != "y" ] && exit 1
    fi

    if ip route | grep -q "$svc_net"; then
        log_warn "Сеть $SERVICE_CIDR может конфликтовать с существующими маршрутами!"
        ip route | grep "$svc_net"
        read -p "Продолжить? (y/n): " response
        [ "$response" != "y" ] && exit 1
    fi

    log_info "Сетевые конфликты не обнаружены"
}

#-------------------------------------------------------------------------------
# Проверка файлов
#-------------------------------------------------------------------------------
check_files() {
    log_info "Проверка файлов..."

    local required_files=(
        "$SCRIPT_DIR/k3s"
        "$SCRIPT_DIR/install-k3s.sh"
        "$SCRIPT_DIR/awx-operator-full.yaml"
        "$IMAGES_DIR/k3s-airgap-images-amd64.tar.zst"
        "$IMAGES_DIR/kustomize.tar.gz"
        "$IMAGES_DIR/awx-operator.tar"
        "$IMAGES_DIR/awx.tar"
        "$IMAGES_DIR/awx-ee.tar"
        "$IMAGES_DIR/kube-rbac-proxy.tar"
        "$IMAGES_DIR/postgresql.tar"
        "$IMAGES_DIR/centos.tar"
        "$IMAGES_DIR/redis.tar"
    )

    local missing=()
    for file in "${required_files[@]}"; do
        [ ! -f "$file" ] && missing+=("$file")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Отсутствуют файлы:"
        printf '  - %s\n' "${missing[@]}"
        exit 1
    fi

    log_info "Все файлы на месте"
}

#-------------------------------------------------------------------------------
# Создание директорий для хранилища
#-------------------------------------------------------------------------------
create_storage_directories() {
    if [ "$CUSTOM_STORAGE_ENABLED" != "true" ]; then
        log_info "Кастомное хранилище отключено, используются пути по умолчанию"
        return
    fi

    log_step "Создание директорий для хранилища..."

    # Создание директорий
    mkdir -p "$POSTGRES_DATA_DIR"
    mkdir -p "$PROJECTS_DATA_DIR"

    # ВАЖНО: PostgreSQL требует права 700 и владельца UID 26
    chown -R 26:26 "$POSTGRES_DATA_DIR"
    chmod 700 "$POSTGRES_DATA_DIR"

    # Права для остальных директорий
    chmod 755 "$AWX_DATA_DIR"
    chmod 755 "$PROJECTS_DATA_DIR"

    log_info "Директории созданы:"
    log_info "  PostgreSQL: $POSTGRES_DATA_DIR (владелец: 26:26, права: 700)"
    log_info "  Projects:   $PROJECTS_DATA_DIR"
}

#-------------------------------------------------------------------------------
# Установка K3s
#-------------------------------------------------------------------------------
install_k3s() {
    log_step "[1/7] Установка K3s..."

    # Копирование бинарника
    cp "$SCRIPT_DIR/k3s" /usr/local/bin/k3s
    chmod +x /usr/local/bin/k3s

    # Air-gap образы ТОЛЬКО в стандартную директорию K3s
    mkdir -p /var/lib/rancher/k3s/agent/images/
    cp "$IMAGES_DIR/k3s-airgap-images-amd64.tar.zst" \
       /var/lib/rancher/k3s/agent/images/

    # Параметры запуска - ТОЛЬКО сеть, без изменения путей K3s
    local k3s_exec="server"
    k3s_exec+=" --cluster-cidr=${POD_CIDR}"
    k3s_exec+=" --service-cidr=${SERVICE_CIDR}"
    k3s_exec+=" --write-kubeconfig-mode=644"

    # Запуск установки
    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_EXEC="$k3s_exec" \
        "$SCRIPT_DIR/install-k3s.sh"

    log_info "K3s установлен"
}

#-------------------------------------------------------------------------------
# Настройка kubeconfig
#-------------------------------------------------------------------------------
setup_kubeconfig() {
    log_step "[2/7] Настройка kubeconfig..."

    if [ -n "$SUDO_USER" ]; then
        REAL_USER="$SUDO_USER"
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        REAL_USER="$USER"
        REAL_HOME="$HOME"
    fi

    mkdir -p "$REAL_HOME/.kube"
    cp /etc/rancher/k3s/k3s.yaml "$REAL_HOME/.kube/config"
    chown -R "$(id -u $REAL_USER):$(id -g $REAL_USER)" "$REAL_HOME/.kube"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    grep -q "KUBECONFIG" "$REAL_HOME/.bashrc" 2>/dev/null || \
        echo 'export KUBECONFIG=~/.kube/config' >> "$REAL_HOME/.bashrc"

    log_info "kubeconfig настроен"
}

#-------------------------------------------------------------------------------
# Ожидание готовности K3s
#-------------------------------------------------------------------------------
wait_for_k3s() {
    log_step "[3/7] Ожидание готовности K3s..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if ! systemctl is-active --quiet k3s; then
        log_error "Служба K3s не запущена"
        systemctl status k3s
        exit 1
    fi

    local timeout=120
    local elapsed=0

    until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
        [ $elapsed -ge $timeout ] && {
            log_error "Таймаут ожидания K3s"
            exit 1
        }
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    log_info "K3s готов"
    kubectl get nodes
}

#-------------------------------------------------------------------------------
# Импорт образов
#-------------------------------------------------------------------------------
import_images() {
    log_step "[4/7] Импорт Docker-образов..."

    local images=(
        "awx-operator.tar"
        "awx.tar"
        "awx-ee.tar"
        "kube-rbac-proxy.tar"
        "postgresql.tar"
        "centos.tar"
        "redis.tar"
    )

    for img in "${images[@]}"; do
        [ -f "$IMAGES_DIR/$img" ] && {
            log_info "  Импорт $img..."
            k3s ctr images import "$IMAGES_DIR/$img" 2>&1 || true
        }
    done

    # Создание тега для kube-rbac-proxy
    k3s ctr images tag \
        quay.io/brancz/kube-rbac-proxy:v0.18.0 \
        gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0 2>/dev/null || true

    log_info "Образы импортированы"
}

#-------------------------------------------------------------------------------
# Установка Kustomize
#-------------------------------------------------------------------------------
install_kustomize() {
    log_step "[5/7] Установка Kustomize..."

    tar xzf "$IMAGES_DIR/kustomize.tar.gz" -C /tmp
    mv /tmp/kustomize /usr/local/bin/
    chmod +x /usr/local/bin/kustomize

    log_info "Kustomize установлен"
}

#-------------------------------------------------------------------------------
# Создание StorageClass и PV для кастомного хранилища
#-------------------------------------------------------------------------------
create_custom_storage() {
    if [ "$CUSTOM_STORAGE_ENABLED" != "true" ]; then
        return
    fi

    log_step "[6/7] Настройка кастомного хранилища..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Получение имени ноды
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

    # Создание StorageClass
    cat <<STORAGE_EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: awx-local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
STORAGE_EOF

    # PV для PostgreSQL
    cat <<PV_POSTGRES_EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: awx-postgres-pv
  labels:
    type: local
    app: awx-postgres
spec:
  storageClassName: awx-local-storage
  capacity:
    storage: ${POSTGRES_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: "${POSTGRES_DATA_DIR}"
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
PV_POSTGRES_EOF

    # PV для Projects
    cat <<PV_PROJECTS_EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: awx-projects-pv
  labels:
    type: local
    app: awx-projects
spec:
  storageClassName: awx-local-storage
  capacity:
    storage: ${PROJECTS_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: "${PROJECTS_DATA_DIR}"
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
PV_PROJECTS_EOF

    log_info "Кастомное хранилище настроено"
    kubectl get pv
}

#-------------------------------------------------------------------------------
# Генерация манифеста AWX Instance
#-------------------------------------------------------------------------------
generate_awx_manifest() {
    log_info "Генерация манифеста AWX..."

    local storage_class="local-path"
    [ "$CUSTOM_STORAGE_ENABLED" = "true" ] && storage_class="awx-local-storage"

    cat <<AWX_MANIFEST_EOF > "$SCRIPT_DIR/awx-instance.yaml"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: ${AWX_INSTANCE_NAME}
  namespace: ${AWX_NAMESPACE}
spec:
  service_type: NodePort
  nodeport_port: ${AWX_NODE_PORT}

  # PostgreSQL
  postgres_storage_class: ${storage_class}
  postgres_storage_requirements:
    requests:
      storage: ${POSTGRES_STORAGE_SIZE}

  # Projects
  projects_persistence: true
  projects_storage_class: ${storage_class}
  projects_storage_size: ${PROJECTS_STORAGE_SIZE}
  projects_storage_access_mode: ReadWriteOnce

  # Web Resources
  web_resource_requirements:
    requests:
      cpu: "${AWX_WEB_CPU_REQUEST}"
      memory: "${AWX_WEB_MEMORY_REQUEST}"
    limits:
      cpu: "${AWX_WEB_CPU_LIMIT}"
      memory: "${AWX_WEB_MEMORY_LIMIT}"

  # Task Resources
  task_resource_requirements:
    requests:
      cpu: "${AWX_TASK_CPU_REQUEST}"
      memory: "${AWX_TASK_MEMORY_REQUEST}"
    limits:
      cpu: "${AWX_TASK_CPU_LIMIT}"
      memory: "${AWX_TASK_MEMORY_LIMIT}"

  # Execution Environment Resources
  ee_resource_requirements:
    requests:
      cpu: "${AWX_EE_CPU_REQUEST}"
      memory: "${AWX_EE_MEMORY_REQUEST}"
    limits:
      cpu: "${AWX_EE_CPU_LIMIT}"
      memory: "${AWX_EE_MEMORY_LIMIT}"
AWX_MANIFEST_EOF

    log_info "Манифест AWX создан"
}

#-------------------------------------------------------------------------------
# Установка AWX
#-------------------------------------------------------------------------------
install_awx() {
    log_step "[7/7] Установка AWX..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Создание namespace
    kubectl create namespace "$AWX_NAMESPACE" 2>/dev/null || true

    # Генерация манифеста
    generate_awx_manifest

    # Установка оператора
    log_info "Применение манифеста AWX Operator..."
    kubectl apply -f "$SCRIPT_DIR/awx-operator-full.yaml"

    # Ожидание оператора
    log_info "Ожидание AWX Operator..."
    local timeout=300
    local elapsed=0

    until kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null | grep "awx-operator" | grep -q "2/2.*Running"; do
        [ $elapsed -ge $timeout ] && {
            log_error "Таймаут ожидания AWX Operator"
            kubectl -n "$AWX_NAMESPACE" get pods
            exit 1
        }
        [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ] && {
            echo ""
            kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null || true
        }
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo ""
    log_info "AWX Operator готов"

    # Установка AWX
    log_info "Применение манифеста AWX..."
    kubectl apply -f "$SCRIPT_DIR/awx-instance.yaml"
}

#-------------------------------------------------------------------------------
# Ожидание AWX
#-------------------------------------------------------------------------------
wait_for_awx() {
    log_info "Ожидание готовности AWX (5-15 минут)..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local timeout=900
    local elapsed=0

    until kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null | grep "awx-web" | grep -q "3/3.*Running"; do
        [ $elapsed -ge $timeout ] && {
            log_warn "Таймаут, но AWX может ещё запускаться"
            break
        }
        [ $((elapsed % 30)) -eq 0 ] && {
            echo ""
            kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null | grep -E "awx-|postgres" || true
        }
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo ""
}

#-------------------------------------------------------------------------------
# Создание скриптов проверки
#-------------------------------------------------------------------------------
create_helper_scripts() {
    if [ -n "$SUDO_USER" ]; then
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        REAL_USER="$SUDO_USER"
    else
        REAL_HOME="$HOME"
        REAL_USER="$USER"
    fi

    # Скрипт проверки AWX
    cat <<'CHECK_AWX_EOF' > "$REAL_HOME/check-awx.sh"
#!/bin/bash
echo "=== Проверка AWX ==="
echo ""
echo "[1] Статус K3s:"
sudo systemctl status k3s --no-pager | grep "Active:" || echo "K3s не запущен"
echo ""
echo "[2] Статус подов AWX:"
kubectl -n awx get pods 2>/dev/null || echo "Ошибка"
echo ""
echo "[3] Сервисы:"
kubectl -n awx get svc 2>/dev/null || echo "Ошибка"
echo ""
echo "[4] PVC:"
kubectl -n awx get pvc 2>/dev/null || echo "Ошибка"
echo ""
echo "[5] Веб-интерфейс:"
IP=$(hostname -I | awk '{print $1}')
PORT=$(kubectl -n awx get svc awx-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$IP:$PORT" 2>/dev/null)
[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] && echo "  ✓ http://$IP:$PORT" || echo "  ✗ Недоступен"
echo ""
echo "[6] Пароль admin:"
kubectl -n awx get secret awx-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode && echo ""
echo ""
CHECK_AWX_EOF

    # Скрипт проверки сети
    cat <<'CHECK_NET_EOF' > "$REAL_HOME/check-k3s-network.sh"
#!/bin/bash
echo "=== K3s Network ==="
echo ""
echo "[1] Node IP: $(hostname -I | awk '{print $1}')"
echo ""
echo "[2] Pod CIDR: $(cat /var/lib/rancher/k3s/agent/etc/flannel/net-conf.json 2>/dev/null | grep -oP '"Network"\s*:\s*"\K[^"]+')"
echo ""
echo "[3] Service CIDR: $(kubectl cluster-info dump 2>/dev/null | grep -m1 'service-cluster-ip-range' | grep -oP '\d+\.\d+\.\d+\.\d+/\d+')"
echo ""
echo "[4] Pod IPs:"
kubectl get pods -A -o wide 2>/dev/null | awk 'NR>1 {print "  "$2": "$7}' | head -10
echo ""
echo "[5] Service IPs:"
kubectl get svc -A 2>/dev/null | awk 'NR>1 && $4!="None" {print "  "$2": "$4}' | head -10
echo ""
CHECK_NET_EOF

    # Скрипт проверки хранилища
    cat <<'CHECK_STORAGE_EOF' > "$REAL_HOME/check-storage.sh"
#!/bin/bash
echo "=== AWX Storage ==="
echo ""
echo "[1] Persistent Volumes:"
kubectl get pv 2>/dev/null || echo "Ошибка"
echo ""
echo "[2] Persistent Volume Claims:"
kubectl -n awx get pvc 2>/dev/null || echo "Ошибка"
echo ""
echo "[3] Размер данных:"
for dir in /var/awx/data/postgres /var/awx/data/projects /var/lib/rancher/k3s/storage; do
    [ -d "$dir" ] && echo "  $dir: $(sudo du -sh "$dir" 2>/dev/null | cut -f1)" || echo "  $dir: не существует"
done
echo ""
CHECK_STORAGE_EOF

    chmod +x "$REAL_HOME/check-awx.sh"
    chmod +x "$REAL_HOME/check-k3s-network.sh"
    chmod +x "$REAL_HOME/check-storage.sh"
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/check-awx.sh"
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/check-k3s-network.sh"
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/check-storage.sh"

    log_info "Скрипты проверки созданы"
}

#-------------------------------------------------------------------------------
# Вывод информации
#-------------------------------------------------------------------------------
print_info() {
    local IP=$(hostname -I | awk '{print $1}')
    local PASSWORD=$(kubectl -n "$AWX_NAMESPACE" get secret awx-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null)

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}          AWX 24.6.1 УСТАНОВЛЕН УСПЕШНО${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}Сеть:${NC}"
    echo "  Pod CIDR:     $POD_CIDR"
    echo "  Service CIDR: $SERVICE_CIDR"
    echo ""
    echo -e "${CYAN}Хранилище:${NC}"
    if [ "$CUSTOM_STORAGE_ENABLED" = "true" ]; then
        echo "  PostgreSQL: $POSTGRES_DATA_DIR"
        echo "  Projects:   $PROJECTS_DATA_DIR"
    else
        echo "  Используется: /var/lib/rancher/k3s/storage/"
    fi
    echo ""
    echo "Статус подов:"
    kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null || true
    echo ""
    echo "------------------------------------------------------------------------"
    echo ""
    echo -e "URL:      ${BLUE}http://${IP}:${AWX_NODE_PORT}${NC}"
    echo -e "Логин:    ${YELLOW}admin${NC}"
    [ -n "$PASSWORD" ] && echo -e "Пароль:   ${YELLOW}${PASSWORD}${NC}"
    echo ""
    echo "------------------------------------------------------------------------"
    echo ""
    echo "Скрипты проверки:"
    echo "  ~/check-awx.sh          # Статус AWX"
    echo "  ~/check-k3s-network.sh  # Сетевая конфигурация"
    echo "  ~/check-storage.sh      # Хранилище"
    echo ""
    echo "========================================================================"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "========================================================================"
    echo "          УСТАНОВКА AWX 24.6.1 (OFFLINE) С КАСТОМИЗАЦИЕЙ"
    echo "========================================================================"
    echo ""

    check_root
    load_config
    print_config

    read -p "Продолжить установку с этими параметрами? (y/n): " response
    [ "$response" != "y" ] && {
        echo "Отредактируйте $CONFIG_FILE и запустите снова"
        exit 0
    }

    check_network_conflicts
    check_files
    create_storage_directories
    install_k3s
    setup_kubeconfig
    wait_for_k3s
    import_images
    install_kustomize
    create_custom_storage
    install_awx
    wait_for_awx
    create_helper_scripts
    print_info
}

main "$@"
INSTALL_SCRIPT

    chmod +x "$DIST_DIR/install-awx-offline.sh"
    log_info "Установочный скрипт создан"
}

#-------------------------------------------------------------------------------
create_readme() {
    log_info "Создание README..."

    cat <<'README_EOF' > "$DIST_DIR/README.md"
# AWX 24.6.1 Offline Installation

## Быстрый старт

1. Отредактируйте конфигурацию:
   ```bash
   nano awx-config.env
   ```

2. Запустите установку:
   ```bash
   sudo ./install-awx-offline.sh
   ```

## Конфигурация (awx-config.env)

### Сеть
```bash
POD_CIDR="192.168.168.0/24"      # Сеть для подов
SERVICE_CIDR="192.168.169.0/24"  # Сеть для сервисов
AWX_NODE_PORT="30080"            # Порт веб-интерфейса
```

### Хранилище
```bash
CUSTOM_STORAGE_ENABLED="true"    # Кастомные пути
AWX_DATA_DIR="/var/awx/data"     # Базовая директория
```

### Ресурсы
```bash
AWX_WEB_CPU_LIMIT="2000m"
AWX_WEB_MEMORY_LIMIT="4Gi"
```

## Важно

- K3s всегда устанавливается в /var/lib/rancher/k3s (не изменять!)
- PostgreSQL требует права 700 и владельца UID 26
- Сетевые диапазоны не должны пересекаться с вашей сетью

## Проверка

```bash
~/check-awx.sh          # Статус AWX
~/check-k3s-network.sh  # Сеть
~/check-storage.sh      # Хранилище
```

## Доступ

- URL: http://<IP>:30080
- Логин: admin
- Пароль: kubectl -n awx get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d
README_EOF
}

#-------------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "========================================================================"
    echo -e "${GREEN}          ДИСТРИБУТИВ AWX OFFLINE СОЗДАН${NC}"
    echo "========================================================================"
    echo ""
    echo "Расположение: $DIST_DIR"
    echo ""
    echo "Структура:"
    echo "  awx-offline/"
    echo "  ├── awx-config.env          # Конфигурация (РЕДАКТИРОВАТЬ!)"
    echo "  ├── install-awx-offline.sh  # Скрипт установки"
    echo "  ├── awx-operator-full.yaml  # Манифест оператора"
    echo "  ├── k3s                     # Бинарник K3s"
    echo "  ├── install-k3s.sh          # Установщик K3s"
    echo "  ├── README.md               # Документация"
    echo "  └── Images/                 # Docker-образы"
    echo ""
    echo "Размер: $(du -sh "$DIST_DIR" | cut -f1)"
    echo ""
    echo "------------------------------------------------------------------------"
    echo ""
    echo "Создание архива:"
    echo "  cd ~ && tar czvf awx-offline-bundle.tar.gz awx-offline/"
    echo ""
    echo "Установка:"
    echo "  1. Перенесите архив на сервер"
    echo "  2. tar xzvf awx-offline-bundle.tar.gz"
    echo "  3. cd awx-offline"
    echo "  4. nano awx-config.env    # Настройте параметры"
    echo "  5. sudo ./install-awx-offline.sh"
    echo ""
    echo "========================================================================"
}

#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "========================================================================"
    echo "          СОЗДАНИЕ ДИСТРИБУТИВА AWX 24.6.1 OFFLINE"
    echo "========================================================================"
    echo ""

    check_dependencies
    create_directories
    download_k3s
    download_kustomize
    download_images
    create_operator_manifest
    create_config_file
    create_install_script
    create_readme
    print_summary
}

main "$@"
SCRIPT

chmod +x ~/create-awx-offline.sh
```

### Шаг 2.3: Запуск скрипта подготовки

```bash
~/create-awx-offline.sh
```

### Шаг 2.4: Создание архива

```bash
cd ~
tar czvf awx-offline-bundle.tar.gz awx-offline/
```

Размер архива: **~2–2.5 ГБ**

---

## Часть 3: Установка на целевом сервере

### Шаг 3.1: Перенос и распаковка

```bash
cd /tmp
tar xzvf awx-offline-bundle.tar.gz
cd awx-offline
```

### Шаг 3.2: Редактирование конфигурации

```bash
nano awx-config.env
```

### Шаг 3.3: Запуск установки

```bash
sudo ./install-awx-offline.sh
```

---

## Часть 4: Примеры конфигурации

### Пример 1: Установка по умолчанию

```bash
# awx-config.env
POD_CIDR="192.168.168.0/24"
SERVICE_CIDR="192.168.169.0/24"
AWX_NODE_PORT="30080"
CUSTOM_STORAGE_ENABLED="false"
```

### Пример 2: Кастомное хранилище

```bash
# awx-config.env
POD_CIDR="192.168.168.0/24"
SERVICE_CIDR="192.168.169.0/24"
AWX_NODE_PORT="30080"

CUSTOM_STORAGE_ENABLED="true"
AWX_DATA_DIR="/var/awx/data"
POSTGRES_DATA_DIR="/var/awx/data/postgres"
PROJECTS_DATA_DIR="/var/awx/data/projects"
POSTGRES_STORAGE_SIZE="50Gi"
PROJECTS_STORAGE_SIZE="20Gi"
```

### Пример 3: Продакшн с увеличенными ресурсами

```bash
# awx-config.env
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
```

---

## Часть 5: Проверка установки

### Скрипты проверки

```bash
~/check-awx.sh          # Статус AWX
~/check-k3s-network.sh  # Сетевая конфигурация
~/check-storage.sh      # Хранилище
```

### Доступ к веб-интерфейсу

```
http://<IP-сервера>:30080
```

- **Логин:** `admin`
- **Пароль:** выводится в конце установки или:

```bash
kubectl -n awx get secret awx-admin-password -o jsonpath='{.data.password}' | base64 --decode; echo
```

---

## Часть 6: Структура хранилища

### При CUSTOM_STORAGE_ENABLED="false"

```
/var/lib/rancher/k3s/storage/
├── pvc-xxx_awx_postgres-15-awx-postgres-15-0/
│   └── userdata/data/       # База данных PostgreSQL
└── pvc-xxx_awx_awx-projects-claim/
    └── _1/, _2/, ...        # Проекты AWX
```

### При CUSTOM_STORAGE_ENABLED="true"

```
/var/awx/data/
├── postgres/                # База данных PostgreSQL
│   └── data/               # Владелец: 26:26, права: 700
└── projects/                # Проекты AWX
    └── _1/, _2/, ...

/var/lib/rancher/k3s/        # K3s (НЕ ИЗМЕНЯТЬ!)
├── agent/
│   ├── containerd/         # Образы контейнеров
│   └── images/             # Air-gap образы
└── server/
    └── db/                 # Состояние кластера
```

---

## Часть 7: Устранение неполадок

### Проблема: PostgreSQL в CrashLoopBackOff

**Причина:** Неправильные права на директорию данных.

**Решение:**

```bash
sudo chown -R 26:26 /var/awx/data/postgres
sudo chmod 700 /var/awx/data/postgres
kubectl -n awx delete pod awx-postgres-15-0
```

### Проблема: K3s не запускается (containerd.sock not found)

**Причина:** Попытка изменить пути K3s/containerd.

**Решение:**

```bash
# Полная очистка
sudo /usr/local/bin/k3s-uninstall.sh
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /etc/rancher/k3s

# Убедитесь, что в awx-config.env НЕТ:
# - CONTAINERD_DATA_DIR
# - K3S_DATA_DIR (или он равен /var/lib/rancher/k3s)

# Переустановка
sudo ./install-awx-offline.sh
```

### Проблема: Таймаут ожидания K3s

**Решение:**

```bash
# Проверка статуса
sudo systemctl status k3s
sudo journalctl -u k3s -n 50

# Ручная проверка
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes
```

### Проблема: ImagePullBackOff

**Решение:**

```bash
# Проверка образов
sudo k3s ctr images list | grep awx

# Ручной импорт
sudo k3s ctr images import /path/to/Images/awx.tar
```

### Проблема: PVC в Pending

```bash
kubectl -n awx describe pvc
kubectl get pv
```

**Решение:** Проверьте, что директории существуют и имеют правильные права.

---

## Часть 8: Полезные команды

### Управление

```bash
# Статус подов
kubectl -n awx get pods

# Логи PostgreSQL
kubectl -n awx logs awx-postgres-15-0

# Логи AWX Web
kubectl -n awx logs -l app.kubernetes.io/name=awx-web -c awx-web

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
  name: backup-$(date +%Y%m%d)
  namespace: awx
spec:
  deployment_name: awx
EOF

# Ручное
sudo tar czvf awx-postgres-backup.tar.gz /var/awx/data/postgres/
sudo tar czvf awx-projects-backup.tar.gz /var/awx/data/projects/
```

### Полное удаление

```bash
kubectl delete -f ~/awx-offline/awx-instance.yaml
kubectl delete -f ~/awx-offline/awx-operator-full.yaml
kubectl delete namespace awx
sudo /usr/local/bin/k3s-uninstall.sh
sudo rm -rf /var/awx/data

# Остановка службы
sudo systemctl stop k3s 2>/dev/null

# Ручная очистка
sudo systemctl disable k3s 2>/dev/null
sudo rm -f /etc/systemd/system/k3s.service
sudo rm -f /etc/systemd/system/k3s.service.env
sudo systemctl daemon-reload

# Удаление данных K3s
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /etc/rancher/k3s
sudo rm -rf /run/k3s
sudo rm -f /usr/local/bin/k3s
sudo rm -f /usr/local/bin/kubectl
sudo rm -f /usr/local/bin/crictl
sudo rm -f /usr/local/bin/ctr

# Очистка iptables (опционально)
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F

```

---

## Сводка параметров конфигурации

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `POD_CIDR` | Сеть для подов | `192.168.168.0/24` |
| `SERVICE_CIDR` | Сеть для сервисов | `192.168.169.0/24` |
| `AWX_NODE_PORT` | Порт веб-интерфейса | `30080` |
| `CUSTOM_STORAGE_ENABLED` | Кастомные пути | `false` |
| `AWX_DATA_DIR` | Базовая директория | `/var/awx/data` |
| `POSTGRES_DATA_DIR` | Путь для PostgreSQL | `${AWX_DATA_DIR}/postgres` |
| `PROJECTS_DATA_DIR` | Путь для проектов | `${AWX_DATA_DIR}/projects` |
| `POSTGRES_STORAGE_SIZE` | Размер тома БД | `10Gi` |
| `PROJECTS_STORAGE_SIZE` | Размер тома проектов | `8Gi` |
| `AWX_WEB_CPU_LIMIT` | CPU лимит web | `2000m` |
| `AWX_WEB_MEMORY_LIMIT` | Память лимит web | `4Gi` |
| `AWX_TASK_CPU_LIMIT` | CPU лимит task | `2000m` |
| `AWX_TASK_MEMORY_LIMIT` | Память лимит task | `4Gi` |

---

## Контрольный список установки

- [ ] Подготовлена машина с Docker и интернетом
- [ ] Запущен `~/create-awx-offline.sh`
- [ ] Создан архив `awx-offline-bundle.tar.gz`
- [ ] Архив перенесён на целевой сервер
- [ ] Архив распакован: `tar xzvf awx-offline-bundle.tar.gz`
- [ ] Отредактирован `awx-config.env`
- [ ] Запущен `sudo ./install-awx-offline.sh`
- [ ] Подтверждена конфигурация (y)
- [ ] Все поды в статусе Running
- [ ] Веб-интерфейс доступен
- [ ] Успешный вход под `admin`

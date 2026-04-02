#!/bin/bash
set -e

#===============================================================================
# install-awx-offline.sh
# Скрипт установки AWX 24.6.1 (offline) с кастомизацией
# Версия: 1.1 (с исправлениями для кастомного хранилища)
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
    echo -e "${CYAN}AWX:${NC}"
    echo "  Instance Name:   $AWX_INSTANCE_NAME"
    echo "  Namespace:       $AWX_NAMESPACE"
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

    # Создание базовой директории
    mkdir -p "$AWX_DATA_DIR"
    chmod 755 "$AWX_DATA_DIR"

    # Создание директории PostgreSQL
    mkdir -p "$POSTGRES_DATA_DIR"
    # ВАЖНО: PostgreSQL требует права 700 и владельца UID 26
    chown -R 26:26 "$POSTGRES_DATA_DIR"
    chmod 700 "$POSTGRES_DATA_DIR"

    # Создание директории Projects
    mkdir -p "$PROJECTS_DATA_DIR"
    chmod 755 "$PROJECTS_DATA_DIR"

    log_info "Директории созданы:"
    log_info "  PostgreSQL: $POSTGRES_DATA_DIR (владелец: 26:26, права: 700)"
    log_info "  Projects:   $PROJECTS_DATA_DIR"

    # Проверка
    ls -la "$AWX_DATA_DIR"
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

    log_info "kubeconfig настроен для пользователя $REAL_USER"
}

#-------------------------------------------------------------------------------
# Ожидание готовности K3s
#-------------------------------------------------------------------------------
wait_for_k3s() {
    log_step "[3/7] Ожидание готовности K3s..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Проверка службы
    local timeout=60
    local elapsed=0

    until systemctl is-active --quiet k3s; do
        if [ $elapsed -ge $timeout ]; then
            log_error "Служба K3s не запустилась"
            systemctl status k3s --no-pager || true
            exit 1
        fi
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Ожидание готовности ноды
    timeout=120
    elapsed=0

    until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
        if [ $elapsed -ge $timeout ]; then
            log_error "Таймаут ожидания K3s"
            log_error "Статус службы:"
            systemctl status k3s --no-pager || true
            log_error "Логи:"
            journalctl -u k3s --no-pager -n 20 || true
            exit 1
        fi
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
        if [ -f "$IMAGES_DIR/$img" ]; then
            log_info "  Импорт $img..."
            k3s ctr images import "$IMAGES_DIR/$img" 2>&1 || {
                log_warn "  Повторная попытка для $img..."
                sleep 2
                k3s ctr images import "$IMAGES_DIR/$img" 2>&1 || true
            }
        else
            log_warn "  Файл не найден: $img"
        fi
    done

    # Создание тега для kube-rbac-proxy
    log_info "  Создание тега для kube-rbac-proxy..."
    k3s ctr images tag \
        quay.io/brancz/kube-rbac-proxy:v0.18.0 \
        gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0 2>/dev/null || true

    log_info "Образы импортированы"
    
    # Проверка
    log_info "Проверка образов:"
    k3s ctr images list | grep -E "awx|postgres|redis" | head -10
}

#-------------------------------------------------------------------------------
# Установка Kustomize
#-------------------------------------------------------------------------------
install_kustomize() {
    log_step "[5/7] Установка Kustomize..."

    tar xzf "$IMAGES_DIR/kustomize.tar.gz" -C /tmp
    mv /tmp/kustomize /usr/local/bin/
    chmod +x /usr/local/bin/kustomize

    log_info "Kustomize установлен: $(kustomize version --short 2>/dev/null || echo 'OK')"
}

#-------------------------------------------------------------------------------
# Создание StorageClass и PV для кастомного хранилища
#-------------------------------------------------------------------------------
create_custom_storage() {
    if [ "$CUSTOM_STORAGE_ENABLED" != "true" ]; then
        log_info "Кастомное хранилище отключено, пропуск шага 6"
        return
    fi

    log_step "[6/7] Настройка кастомного хранилища..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Получение имени ноды
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    log_info "Имя ноды: $node_name"

    # Создание StorageClass
    log_info "Создание StorageClass..."
    cat <<STORAGE_EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: awx-local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
reclaimPolicy: Retain
STORAGE_EOF

    # PV для PostgreSQL с claimRef для привязки к конкретному PVC
    log_info "Создание PV для PostgreSQL..."
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
  claimRef:
    namespace: ${AWX_NAMESPACE}
    name: postgres-15-${AWX_INSTANCE_NAME}-postgres-15-0
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

    # PV для Projects с claimRef
    log_info "Создание PV для Projects..."
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
  claimRef:
    namespace: ${AWX_NAMESPACE}
    name: ${AWX_INSTANCE_NAME}-projects-claim
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
    echo ""
    kubectl get pv
    echo ""
}

#-------------------------------------------------------------------------------
# Генерация манифеста AWX Instance
#-------------------------------------------------------------------------------
generate_awx_manifest() {
    log_info "Генерация манифеста AWX..."

    local storage_class="local-path"
    [ "$CUSTOM_STORAGE_ENABLED" = "true" ] && storage_class="awx-local-storage"

    cat > "$SCRIPT_DIR/awx-instance.yaml" <<AWX_MANIFEST_EOF
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

    log_info "Манифест AWX создан: $SCRIPT_DIR/awx-instance.yaml"
}

#-------------------------------------------------------------------------------
# Установка AWX
#-------------------------------------------------------------------------------
install_awx() {
    log_step "[7/7] Установка AWX..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Генерация манифеста AWX Instance
    generate_awx_manifest

    # Установка оператора
    log_info "Применение манифеста AWX Operator..."
    kubectl apply -f "$SCRIPT_DIR/awx-operator-full.yaml"

    # Ожидание готовности оператора
    log_info "Ожидание готовности AWX Operator..."
    local timeout=300
    local elapsed=0

    until kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null | grep "awx-operator" | grep -q "2/2.*Running"; do
        if [ $elapsed -ge $timeout ]; then
            log_error "Таймаут ожидания AWX Operator"
            kubectl -n "$AWX_NAMESPACE" get pods
            exit 1
        fi
        if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            echo ""
            kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null || true
        fi
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo ""
    log_info "AWX Operator готов"

    # Установка AWX Instance
    log_info "Применение манифеста AWX Instance..."
    kubectl apply -f "$SCRIPT_DIR/awx-instance.yaml"

    log_info "AWX Instance создан, ожидание запуска компонентов..."
}

#-------------------------------------------------------------------------------
# Ожидание готовности AWX
#-------------------------------------------------------------------------------
wait_for_awx() {
    log_info "Ожидание готовности AWX (5-15 минут)..."

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local timeout=900
    local elapsed=0

    until kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null | grep "awx-web" | grep -q "3/3.*Running"; do
        if [ $elapsed -ge $timeout ]; then
            log_warn "Таймаут ожидания, но AWX может ещё запускаться"
            log_warn "Проверьте статус вручную: kubectl -n $AWX_NAMESPACE get pods"
            break
        fi
        if [ $((elapsed % 30)) -eq 0 ]; then
            echo ""
            kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null | grep -E "awx-|postgres" || true
        fi
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo ""
}

#-------------------------------------------------------------------------------
# Копирование скриптов проверки
#-------------------------------------------------------------------------------
copy_helper_scripts() {
    log_info "Копирование скриптов проверки..."

    if [ -n "$SUDO_USER" ]; then
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        REAL_USER="$SUDO_USER"
    else
        REAL_HOME="$HOME"
        REAL_USER="$USER"
    fi

    # Копируем скрипты проверки если они есть
    local copied=0
    for script in check-awx.sh check-k3s-network.sh check-storage.sh; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "$REAL_HOME/"
            chmod +x "$REAL_HOME/$script"
            chown "$REAL_USER:$REAL_USER" "$REAL_HOME/$script"
            copied=$((copied + 1))
        fi
    done

    if [ $copied -gt 0 ]; then
        log_info "Скопировано $copied скриптов в $REAL_HOME/"
    else
        log_warn "Скрипты проверки не найдены в $SCRIPT_DIR/"
    fi
}

#-------------------------------------------------------------------------------
# Вывод информации
#-------------------------------------------------------------------------------
print_info() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local IP=$(hostname -I | awk '{print $1}')
    local PASSWORD=""
    
    # Попытка получить пароль (может не существовать сразу)
    for i in {1..5}; do
        PASSWORD=$(kubectl -n "$AWX_NAMESPACE" get secret ${AWX_INSTANCE_NAME}-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null)
        [ -n "$PASSWORD" ] && break
        sleep 5
    done

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
    echo -e "${CYAN}Статус подов:${NC}"
    kubectl -n "$AWX_NAMESPACE" get pods 2>/dev/null || true
    echo ""
    echo "------------------------------------------------------------------------"
    echo ""
    echo -e "URL:      ${BLUE}http://${IP}:${AWX_NODE_PORT}${NC}"
    echo -e "Логин:    ${YELLOW}admin${NC}"
    if [ -n "$PASSWORD" ]; then
        echo -e "Пароль:   ${YELLOW}${PASSWORD}${NC}"
    else
        echo -e "Пароль:   ${YELLOW}(получить командой ниже)${NC}"
        echo ""
        echo "  kubectl -n $AWX_NAMESPACE get secret ${AWX_INSTANCE_NAME}-admin-password -o jsonpath='{.data.password}' | base64 --decode; echo"
    fi
    echo ""
    echo "------------------------------------------------------------------------"
    echo ""
    echo "Скрипты проверки:"
    echo "  ~/check-awx.sh          # Статус AWX"
    echo "  ~/check-k3s-network.sh  # Сетевая конфигурация"
    echo "  ~/check-storage.sh      # Хранилище"
    echo ""
    echo "Полезные команды:"
    echo "  kubectl -n $AWX_NAMESPACE get pods              # Статус подов"
    echo "  kubectl -n $AWX_NAMESPACE logs <pod-name>       # Логи пода"
    echo "  kubectl -n $AWX_NAMESPACE get pvc               # Состояние хранилища"
    echo ""
    echo "========================================================================"
}

#-------------------------------------------------------------------------------
# Главная функция
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "========================================================================"
    echo "          УСТАНОВКА AWX 24.6.1 (OFFLINE) С КАСТОМИЗАЦИЕЙ"
    echo "========================================================================"
    echo ""

    # Проверки
    check_root
    load_config
    print_config

    # Подтверждение
    read -p "Продолжить установку с этими параметрами? (y/n): " response
    if [ "$response" != "y" ]; then
        echo "Отредактируйте $CONFIG_FILE и запустите снова"
        exit 0
    fi

    echo ""

    # Установка
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
    copy_helper_scripts
    print_info
}

# Запуск
main "$@"

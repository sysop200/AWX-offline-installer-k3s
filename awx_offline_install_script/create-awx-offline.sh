#!/bin/bash
set -e

#===============================================================================
# create-awx-offline.sh
# Скрипт создания offline-дистрибутива AWX 24.6.1
# Запускать на машине с доступом в интернет и установленным Docker
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
# Проверка зависимостей
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
# Создание директорий
#-------------------------------------------------------------------------------
create_directories() {
    log_info "Создание директорий..."
    rm -rf "$DIST_DIR"
    mkdir -p "$IMAGES_DIR"
}

#-------------------------------------------------------------------------------
# Скачивание K3s
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
# Скачивание Kustomize
#-------------------------------------------------------------------------------
download_kustomize() {
    log_info "Скачивание Kustomize ${KUSTOMIZE_VERSION}..."

    curl -Lo "$IMAGES_DIR/kustomize.tar.gz" \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
}

#-------------------------------------------------------------------------------
# Скачивание Docker-образов
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
# Создание манифеста AWX Operator
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
# Копирование дополнительных скриптов
#-------------------------------------------------------------------------------
copy_scripts() {
    log_info "Копирование скриптов..."

    local script_dir="$(dirname "$(readlink -f "$0")")"

    # Копируем скрипты если они есть рядом
    for script in install-awx-offline.sh awx-config.env check-awx.sh check-k3s-network.sh check-storage.sh; do
        if [ -f "$script_dir/$script" ]; then
            cp "$script_dir/$script" "$DIST_DIR/"
            [ -x "$script_dir/$script" ] && chmod +x "$DIST_DIR/$script"
            log_info "  Скопирован: $script"
        else
            log_warn "  Не найден: $script"
        fi
    done

    # Если конфига нет, создаём
    if [ ! -f "$DIST_DIR/awx-config.env" ]; then
        create_config_file
    fi
}

#-------------------------------------------------------------------------------
# Создание конфигурационного файла
#-------------------------------------------------------------------------------
create_config_file() {
    log_info "Создание конфигурационного файла..."

    cat > "$DIST_DIR/awx-config.env" << 'CONFIGEOF'
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
CONFIGEOF
}

#-------------------------------------------------------------------------------
# Вывод информации
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
    echo "  ├── awx-config.env          # Конфигурация"
    echo "  ├── install-awx-offline.sh  # Скрипт установки"
    echo "  ├── awx-operator-full.yaml  # Манифест оператора"
    echo "  ├── k3s                     # Бинарник K3s"
    echo "  ├── install-k3s.sh          # Установщик K3s"
    echo "  ├── check-awx.sh            # Проверка AWX"
    echo "  ├── check-k3s-network.sh    # Проверка сети"
    echo "  ├── check-storage.sh        # Проверка хранилища"
    echo "  └── Images/                 # Docker-образы"
    echo ""
    echo "Размер: $(du -sh "$DIST_DIR" | cut -f1)"
    echo ""
    echo "------------------------------------------------------------------------"
    echo ""
    echo "Создание архива:"
    echo "  cd ~ && tar czvf awx-offline-bundle.tar.gz awx-offline/"
    echo ""
    echo "Установка на целевом сервере:"
    echo "  1. Перенесите архив на сервер"
    echo "  2. tar xzvf awx-offline-bundle.tar.gz"
    echo "  3. cd awx-offline"
    echo "  4. nano awx-config.env"
    echo "  5. sudo ./install-awx-offline.sh"
    echo ""
    echo "========================================================================"
}

#-------------------------------------------------------------------------------
# Main
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
    copy_scripts
    print_summary
}

main "$@"

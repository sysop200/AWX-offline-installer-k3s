#!/bin/bash
#===============================================================================
# check-storage.sh
# Проверка хранилища AWX
#===============================================================================

echo "=== AWX Storage ==="
echo ""

echo "[1] Persistent Volumes:"
kubectl get pv 2>/dev/null || echo "Ошибка получения PV"
echo ""

echo "[2] Persistent Volume Claims:"
kubectl -n awx get pvc 2>/dev/null || echo "Ошибка получения PVC"
echo ""

echo "[3] Размер данных:"
echo ""
echo "  Кастомное хранилище:"
for dir in /var/awx/data/postgres /var/awx/data/projects; do
    if [ -d "$dir" ]; then
        SIZE=$(sudo du -sh "$dir" 2>/dev/null | cut -f1)
        echo "    ✓ $dir: $SIZE"
    else
        echo "    - $dir: не существует"
    fi
done
echo ""
echo "  K3s хранилище:"
if [ -d "/var/lib/rancher/k3s/storage" ]; then
    SIZE=$(sudo du -sh /var/lib/rancher/k3s/storage 2>/dev/null | cut -f1)
    echo "    ✓ /var/lib/rancher/k3s/storage: $SIZE"
else
    echo "    - /var/lib/rancher/k3s/storage: не существует"
fi
echo ""

echo "[4] Права на директории:"
for dir in /var/awx/data/postgres /var/awx/data/projects; do
    if [ -d "$dir" ]; then
        PERMS=$(stat -c "%a %U:%G" "$dir" 2>/dev/null)
        echo "  $dir: $PERMS"
    fi
done
echo ""

echo "=== Проверка завершена ==="


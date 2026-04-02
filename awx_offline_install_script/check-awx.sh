#!/bin/bash
#===============================================================================
# check-awx.sh
# Проверка статуса AWX
#===============================================================================

echo "=== Проверка AWX ==="
echo ""

echo "[1] Статус K3s:"
sudo systemctl status k3s --no-pager | grep "Active:" || echo "K3s не запущен"
echo ""

echo "[2] Статус подов AWX:"
kubectl -n awx get pods 2>/dev/null || echo "Ошибка получения подов"
echo ""

echo "[3] Сервисы:"
kubectl -n awx get svc 2>/dev/null || echo "Ошибка получения сервисов"
echo ""

echo "[4] PVC:"
kubectl -n awx get pvc 2>/dev/null || echo "Ошибка получения PVC"
echo ""

echo "[5] Веб-интерфейс:"
IP=$(hostname -I | awk '{print $1}')
PORT=$(kubectl -n awx get svc awx-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$IP:$PORT" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "  ✓ Доступен: http://$IP:$PORT"
else
    echo "  ✗ Недоступен (HTTP: $HTTP_CODE)"
fi
echo ""

echo "[6] Пароль admin:"
PASSWORD=$(kubectl -n awx get secret awx-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null)
if [ -n "$PASSWORD" ]; then
    echo "  $PASSWORD"
else
    echo "  Секрет ещё не создан"
fi
echo ""

echo "=== Проверка завершена ==="


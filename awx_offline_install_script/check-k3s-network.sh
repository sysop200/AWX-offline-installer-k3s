#!/bin/bash
#===============================================================================
# check-k3s-network.sh
# Проверка сетевой конфигурации K3s
#===============================================================================

echo "=== K3s Network ==="
echo ""

echo "[1] Node IP:"
echo "  $(hostname -I | awk '{print $1}')"
echo ""

echo "[2] Pod CIDR:"
POD_CIDR=$(cat /var/lib/rancher/k3s/agent/etc/flannel/net-conf.json 2>/dev/null | grep -oP '"Network"\s*:\s*"\K[^"]+')
echo "  ${POD_CIDR:-N/A}"
echo ""

echo "[3] Service CIDR:"
SVC_CIDR=$(kubectl cluster-info dump 2>/dev/null | grep -m1 'service-cluster-ip-range' | grep -oP '\d+\.\d+\.\d+\.\d+/\d+')
echo "  ${SVC_CIDR:-N/A}"
echo ""

echo "[4] Pod IPs:"
kubectl get pods -A -o wide 2>/dev/null | awk 'NR>1 {print "  "$2" ("$1"): "$7}' | head -15
echo ""

echo "[5] Service IPs:"
kubectl get svc -A 2>/dev/null | awk 'NR>1 && $4!="None" {print "  "$2" ("$1"): "$4}' | head -15
echo ""

echo "[6] Flannel interface:"
ip addr show flannel.1 2>/dev/null | grep "inet " | awk '{print "  "$2}' || echo "  N/A"
echo ""

echo "[7] Routes:"
ip route | grep -E "192.168.168|192.168.169|flannel|cni" | sed 's/^/  /' || echo "  No custom routes"
echo ""

echo "=== Проверка завершена ==="

